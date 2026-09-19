// lib/data/services/semantic_search_api.dart
//
// DATA LAYER — SERVICE (REMOTE / API CLIENT)
// ------------------------------------------
// This service is the client-side half of the semantic search backend.
// It's usable today — `SwipeScreen`'s search bar and `SwipeController`
// already call into it — but `baseUrl` still points at a placeholder
// until you deploy the actual FastAPI service, so `semanticFilter()`
// fails soft (empty results) rather than erroring.
//
// -----------------------------------------------------------------------
// ARCHITECTURE — AND A CORRECTION FROM AN EARLIER VERSION OF THIS FILE:
//
// An earlier version of this pipeline planned to caption each photo,
// embed the caption with SentenceTransformers, and match search queries
// against those caption embeddings. That's a workable design on its
// own, but it stops being consistent once you bring in MobileCLIP for
// on-device image embedding (see `embedding_worker.dart`): MobileCLIP's
// image and text encoders share ONE joint embedding space by
// construction, so a photo's MobileCLIP embedding and a query's
// MobileCLIP embedding are directly comparable — no caption, and no
// SentenceTransformers, needed in between. Mixing the two (MobileCLIP
// image vectors vs. SentenceTransformers query vectors) would not error;
// it would just silently return meaningless similarity scores, since
// they're different vector spaces.
//
// This file now reflects the MobileCLIP-consistent design:
//
//   Flutter App                              FastAPI Backend
//   ────────────                             ────────────────
//   On-device (embedding_worker.dart):
//     MobileCLIP image encoder (ONNX)
//     embeds each photo thumbnail
//              │
//              ▼
//   uploadEmbedding(assetId, vector)  ─────▶  FAISS index
//                                             (upsert vector, keyed
//                                              by asset_id — no image
//                                              bytes ever sent)
//
//   semanticFilter("mountain treks")  ─────▶  FastAPI embeds the query
//                                             with MobileCLIP's TEXT
//                                             tower (plain PyTorch,
//                                             server-side — no mobile
//                                             constraints apply there),
//                                             then runs a FAISS
//                                             nearest-neighbor search
//                                             over the SAME space the
//                                             image vectors live in
//                                                       │
//   Flutter App  ◀── ranked [{asset_id, score}, ...] ──┘
//
// `uploadAssetMetadata` (the original caption-based path) is kept below,
// clearly marked as an ALTERNATIVE rather than deleted — it's still a
// reasonable design if you'd rather not run any model on-device at all
// and are fine with captioning being the bottleneck on search quality.
// Use one path consistently; don't upload photos via one and query via
// the other.
// -----------------------------------------------------------------------

import 'dart:convert';
import 'package:http/http.dart' as http;

/// A single semantic search hit returned by the backend.
class SemanticSearchResult {
  SemanticSearchResult({required this.assetId, required this.score});

  /// The `photo_manager` asset ID this result corresponds to. The backend
  /// never sees or stores actual image bytes in this design — only
  /// metadata/embeddings keyed by the ID the client already owns.
  final String assetId;

  /// Cosine-similarity (or FAISS L2-derived) relevance score, higher is
  /// more relevant. Exposed so the UI can, e.g., fade out low-confidence
  /// matches instead of a hard cutoff.
  final double score;

  factory SemanticSearchResult.fromJson(Map<String, dynamic> json) {
    return SemanticSearchResult(
      assetId: json['asset_id'] as String,
      score: (json['score'] as num).toDouble(),
    );
  }
}

class SemanticSearchApi {
  SemanticSearchApi({
    this.baseUrl = 'https://your-fastapi-backend.example.com',
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Base URL of the FastAPI backend. Left as a plain constructor
  /// parameter (rather than hardcoded) so it's trivial to point at
  /// localhost during development or swap per build flavor (dev/staging/
  /// prod) via dependency injection at the Riverpod provider level.
  final String baseUrl;

  final http.Client _client;

  /// PRIMARY PATH — upload an already-computed MobileCLIP image
  /// embedding for one photo.
  ///
  /// This is what `EmbeddingIndexer` (in `embedding_worker.dart`) calls
  /// after running the on-device ONNX model on a photo's thumbnail.
  /// [embedding] must already be L2-normalized (the exported model does
  /// this internally — see `export_mobileclip_onnx.py`'s
  /// `ImageEncoderWrapper`) and must be in the SAME dimensionality your
  /// FAISS index was built with (512 for most MobileCLIP variants).
  Future<void> uploadEmbedding({
    required String assetId,
    required List<double> embedding,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/embeddings/upsert_vector');
    try {
      await _client.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'asset_id': assetId,
          'embedding': embedding,
        }),
      );
    } catch (_) {
      // Best-effort background sync — a photo that fails to upload just
      // won't be searchable yet; it never surfaces as a user-facing
      // error (see `EmbeddingIndexer.indexBatch`'s catch-all).
    }
  }

  /// ALTERNATIVE PATH — caption-then-embed, for a backend that does NOT
  /// use MobileCLIP on-device and instead relies on SentenceTransformers
  /// over generated captions. Kept for reference; do not call this AND
  /// `uploadEmbedding` for the same deployment — pick one embedding
  /// space and query it consistently.
  Future<void> uploadAssetMetadata({
    required String assetId,
    String? caption,
    DateTime? capturedAt,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/embeddings/upsert_caption');
    await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'asset_id': assetId,
        'caption': caption,
        'captured_at': capturedAt?.toIso8601String(),
      }),
    );
  }

  /// Semantic query against the FAISS index.
  ///
  /// Example: `semanticFilter("mountain treks")` should return the asset
  /// IDs of photos whose embeddings are nearest-neighbors to the query's
  /// embedding, letting the swipe queue be filtered down to just that
  /// theme (e.g. "only show me photos of mountain treks so I can decide
  /// which to keep").
  ///
  /// Returns an empty list (rather than throwing) on any network/parsing
  /// failure, so a not-yet-deployed backend degrades gracefully to
  /// "semantic filtering unavailable" instead of crashing the swipe flow.
  Future<List<SemanticSearchResult>> semanticFilter(
    String query, {
    int topK = 100,
  }) async {
    final uri = Uri.parse('$baseUrl/v1/search').replace(queryParameters: {
      'q': query,
      'top_k': '$topK',
    });

    try {
      final response = await _client.get(uri);
      if (response.statusCode != 200) return const [];

      final List<dynamic> body = jsonDecode(response.body) as List<dynamic>;
      return body
          .map((e) => SemanticSearchResult.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Backend not deployed yet / network failure — fail soft.
      return const [];
    }
  }
}
