// lib/data/services/embedding_worker.dart
//
// DATA LAYER — SERVICE (ON-DEVICE ML)
// --------------------------------------
// Runs MobileCLIP's image encoder, exported to ONNX (see
// `scripts/export_mobileclip_onnx.py`), on a background isolate to embed
// photo thumbnails into the same vector space a search query gets
// embedded into server-side. This file replaces an earlier version of
// itself that used `compute()` with a placeholder embedding function —
// that was fine as an architecture sketch, but wrong for real use:
// `compute()` spawns a brand-new isolate (and would reload the ~10-25 MB
// model) for every single call, which is far too slow to run 50 times
// per batch. This version spawns ONE long-lived isolate that loads the
// model once and stays warm for the app's lifetime.
//
// -----------------------------------------------------------------------
// WHAT YOU STILL NEED TO DO BEFORE THIS RUNS FOR REAL:
//
//   1. Run `scripts/export_mobileclip_onnx.py` (on your dev machine, not
//      on-device) to produce a `.onnx` file, and copy it into
//      `assets/models/`. See that script's docstring for the exact
//      commands — it needs weights this repo cannot download for you.
//   2. Fill in `kMobileClipInputSize`, `kMobileClipMean`, and
//      `kMobileClipStd` below with the EXACT values the export script
//      printed for your checkpoint. These are not universal constants —
//      guessing them produces a model that runs without error and
//      returns meaningless embeddings.
//   3. Add `flutter_onnxruntime` to `pubspec.yaml` (see the comment
//      there) and register the asset path.
//
// None of the surrounding architecture — the persistent isolate, the
// throttling, the request/response protocol — changes based on which
// MobileCLIP variant you export; only the three constants above do.
// -----------------------------------------------------------------------

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';
import '../models/custom_asset.dart';

/// -----------------------------------------------------------------
/// FILL THESE IN FROM YOUR EXPORT SCRIPT'S PRINTED OUTPUT — see the
/// "COPY THESE THREE VALUES" line in `export_mobileclip_onnx.py`.
/// The values below are MobileCLIP-S0/S1/S2/B's typical settings and
/// are provided only so the file is self-consistent out of the box —
/// treat them as a placeholder, not a verified constant.
/// -----------------------------------------------------------------
const int kMobileClipInputSize = 256;
const List<double> kMobileClipMean = [0.0, 0.0, 0.0];
const List<double> kMobileClipStd = [1.0, 1.0, 1.0];
const String kMobileClipAssetPath =
    'assets/models/mobileclip_s0_image_encoder_fp16.onnx';

/// Signature matching `SemanticSearchApi.uploadAssetMetadata`. Kept as a
/// typedef (rather than importing the networking service directly) so
/// this file's only hard dependency is on-device inference — the "sync
/// the resulting vector somewhere" step is injected by the caller.
typedef VectorUploader = Future<void> Function({
  required String assetId,
  required List<double> embedding,
});

// =======================================================================
// PERSISTENT ISOLATE WORKER
// =======================================================================

/// Owns exactly one background isolate for the lifetime it's used,
/// loading the ONNX session inside that isolate ONCE and then answering
/// as many `embed()` requests as needed over a persistent port — instead
/// of `compute()`'s spawn-per-call model, which would reload the model
/// from the asset bundle on every photo.
class OnDeviceEmbedder {
  Isolate? _isolate;
  SendPort? _commandPort;
  Completer<void>? _ready;

  bool get isReady => _commandPort != null;

  /// Spawns the worker isolate and waits for its ONNX session to finish
  /// loading. Safe to call multiple times — subsequent calls just await
  /// the same startup.
  Future<void> start() async {
    if (_ready != null) return _ready!.future;
    _ready = Completer<void>();

    // Plugin channel calls (like loading a Flutter asset) only work from
    // a background isolate if that isolate is registered with the
    // engine's binary messenger first. `RootIsolateToken.instance` must
    // be read on the MAIN isolate (here) and handed to the spawned
    // isolate — it cannot be looked up from inside the new isolate.
    final rootIsolateToken = RootIsolateToken.instance;
    if (rootIsolateToken == null) {
      _ready!.completeError(StateError(
        'RootIsolateToken unavailable — start() must be called after '
        'WidgetsFlutterBinding.ensureInitialized().',
      ));
      return _ready!.future;
    }

    final initPort = ReceivePort();
    _isolate = await Isolate.spawn(
      _isolateMain,
      _IsolateStartupMessage(initPort.sendPort, rootIsolateToken),
      debugName: 'mobileclip-embedder',
    );

    final firstMessage = await initPort.first;
    initPort.close();

    if (firstMessage is _IsolateStartupError) {
      _ready!.completeError(Exception(firstMessage.message));
    } else {
      _commandPort = firstMessage as SendPort;
      _ready!.complete();
    }

    return _ready!.future;
  }

  /// Embeds one photo, given its already-decoded thumbnail bytes (JPEG,
  /// as returned by `AssetEntity.thumbnailDataWithSize`). Decoding,
  /// resizing, and normalizing all happen INSIDE the worker isolate, so
  /// the only thing crossing the isolate boundary is the raw JPEG bytes
  /// in, and a `List<double>` embedding out.
  Future<List<double>> embed(Uint8List jpegThumbnailBytes) async {
    await start();
    if (_commandPort == null) {
      throw StateError('OnDeviceEmbedder failed to start.');
    }

    final responsePort = ReceivePort();
    _commandPort!.send(_EmbedRequest(jpegThumbnailBytes, responsePort.sendPort));

    final result = await responsePort.first;
    responsePort.close();

    if (result is _EmbedError) {
      throw Exception('Embedding failed: ${result.message}');
    }
    return (result as _EmbedResult).embedding;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commandPort = null;
    _ready = null;
  }
}

// -----------------------------------------------------------------------
// ISOLATE-SIDE CODE
//
// Everything below this line runs on the BACKGROUND isolate, not the UI
// isolate. It cannot close over any state from `OnDeviceEmbedder` — all
// communication happens through the message classes and ports below.
// -----------------------------------------------------------------------

class _IsolateStartupMessage {
  _IsolateStartupMessage(this.mainSendPort, this.rootIsolateToken);
  final SendPort mainSendPort;
  final RootIsolateToken rootIsolateToken;
}

class _IsolateStartupError {
  _IsolateStartupError(this.message);
  final String message;
}

class _EmbedRequest {
  _EmbedRequest(this.jpegBytes, this.replyPort);
  final Uint8List jpegBytes;
  final SendPort replyPort;
}

class _EmbedResult {
  _EmbedResult(this.embedding);
  final List<double> embedding;
}

class _EmbedError {
  _EmbedError(this.message);
  final String message;
}

Future<void> _isolateMain(_IsolateStartupMessage startup) async {
  // Required before this isolate can use ANY Flutter plugin (including
  // loading a bundled asset) — without this, `createSessionFromAsset`
  // below would hang or throw.
  BackgroundIsolateBinaryMessenger.ensureInitialized(startup.rootIsolateToken);

  final commandPort = ReceivePort();

  try {
    final ort = OnnxRuntime();
    final session = await ort.createSessionFromAsset(kMobileClipAssetPath);

    // Only now, once the model is actually loaded, do we tell the main
    // isolate we're ready to accept work.
    startup.mainSendPort.send(commandPort.sendPort);

    await for (final message in commandPort) {
      if (message is _EmbedRequest) {
        try {
          final pixelValues = _preprocess(message.jpegBytes);
          final inputTensor = await OrtValue.fromList(
            pixelValues,
            [1, 3, kMobileClipInputSize, kMobileClipInputSize],
          );
          final outputs = await session.run({'pixel_values': inputTensor});
          final embedding = await outputs['image_embeds']!.asList();
          message.replyPort.send(_EmbedResult(List<double>.from(embedding)));
        } catch (e) {
          message.replyPort.send(_EmbedError(e.toString()));
        }
      }
    }
  } catch (e) {
    startup.mainSendPort.send(_IsolateStartupError(e.toString()));
  }
}

/// Decodes a JPEG thumbnail, resizes it to the model's expected square
/// input, and lays it out as a planar (CHW) Float32 buffer normalized
/// with `kMobileClipMean`/`kMobileClipStd` — the exact preprocessing
/// contract the export script printed for your checkpoint.
///
/// This is real, working image preprocessing (not a stub) — but its
/// CORRECTNESS depends entirely on `kMobileClipInputSize`/`kMobileClipMean`/
/// `kMobileClipStd` above matching your actual exported model.
Float32List _preprocess(Uint8List jpegBytes) {
  final decoded = img.decodeImage(jpegBytes);
  if (decoded == null) {
    throw const FormatException('Could not decode thumbnail as an image.');
  }

  final resized = img.copyResize(
    decoded,
    width: kMobileClipInputSize,
    height: kMobileClipInputSize,
    interpolation: img.Interpolation.cubic,
  );

  const size = kMobileClipInputSize;
  final planar = Float32List(3 * size * size);
  final channelStride = size * size;

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final pixel = resized.getPixel(x, y);
      final r = pixel.r / 255.0;
      final g = pixel.g / 255.0;
      final b = pixel.b / 255.0;
      final index = y * size + x;

      planar[index] = (r - kMobileClipMean[0]) / kMobileClipStd[0];
      planar[channelStride + index] = (g - kMobileClipMean[1]) / kMobileClipStd[1];
      planar[2 * channelStride + index] = (b - kMobileClipMean[2]) / kMobileClipStd[2];
    }
  }

  return planar;
}

// =======================================================================
// BATCH INDEXER — throttled, main-isolate-facing API
// =======================================================================

/// The public entry point `SwipeController` calls after each batch loads.
/// Owns one `OnDeviceEmbedder` for the app's lifetime, and applies the
/// same "back off while the user is actively swiping" throttling as
/// before — that part of the original design didn't need to change.
class EmbeddingIndexer {
  final OnDeviceEmbedder _embedder = OnDeviceEmbedder();

  static const int _maxPerTick = 50;
  static const Duration _throttleRecheckInterval = Duration(milliseconds: 250);

  Future<void> indexBatch(
    List<CustomAsset> batch, {
    required bool Function() isUserActivelySwiping,
    VectorUploader? uploadEmbedding,
  }) async {
    var processed = 0;

    for (final asset in batch) {
      if (processed >= _maxPerTick) break;

      while (isUserActivelySwiping()) {
        await Future.delayed(_throttleRecheckInterval);
      }

      try {
        final thumbnailBytes = await asset.entity.thumbnailDataWithSize(
          const ThumbnailSize.square(kMobileClipInputSize),
        );
        if (thumbnailBytes == null) continue;

        final embedding = await _embedder.embed(thumbnailBytes);
        await uploadEmbedding?.call(assetId: asset.id, embedding: embedding);
      } catch (_) {
        // Best-effort background work: one photo failing to embed (a
        // not-yet-downloaded iCloud asset, a corrupt thumbnail, the
        // model not having been bundled yet during early development)
        // must never surface as an error to the swipe UI.
      }

      processed++;
    }
  }

  void dispose() => _embedder.dispose();
}
