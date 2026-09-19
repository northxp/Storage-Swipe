// lib/data/models/custom_asset.dart
//
// DATA LAYER — MODEL
// -------------------
// This is the "M" in MVVM. `photo_manager`'s native `AssetEntity` is a thin
// wrapper around a platform-side photo/video record — it doesn't carry a
// byte-accurate file size, and it isn't something we want the ViewModel or
// UI reasoning directly about (that would leak the data source's shape
// into every other layer).
//
// `CustomAsset` is our app-level model: it wraps `AssetEntity` and adds the
// derived data our gamification logic actually needs (file size in bytes,
// a human-readable size string). Every other layer (state/, ui/) talks in
// terms of `CustomAsset`, never `AssetEntity`, directly.

import 'package:photo_manager/photo_manager.dart';

class CustomAsset {
  CustomAsset({
    required this.entity,
    required this.fileSizeBytes,
  });

  /// The underlying native asset handle. Kept accessible because the UI
  /// layer needs it to render thumbnails (`AssetEntityImage`), but nothing
  /// outside `data/` should reach into platform-specific fields on it.
  final AssetEntity entity;

  /// Actual on-disk file size in bytes. This is what powers the
  /// "largest files first" sort and the "MB freed" recap calculation.
  final int fileSizeBytes;

  /// Stable identifier used as the dictionary/list key everywhere in state
  /// (trashBuffer, pendingQueue, deletion calls to `photo_manager`).
  String get id => entity.id;

  double get megabytes => fileSizeBytes / (1024 * 1024);

  /// Human-friendly size label for UI display, e.g. "4.2 MB".
  String get formattedSize => '${megabytes.toStringAsFixed(1)} MB';

  /// Builds a [CustomAsset] from a raw [AssetEntity] by resolving its file
  /// size on disk. This does I/O (stats the underlying file), so it's
  /// async and is only ever called from [GalleryService], never from the
  /// UI or state layer directly.
  static Future<CustomAsset> fromEntity(AssetEntity entity) async {
    int size = 0;
    try {
      final file = await entity.originFile;
      size = await file?.length() ?? 0;
    } catch (_) {
      // If the platform can't resolve a file handle (e.g. a cloud-only
      // iCloud asset that hasn't downloaded yet), we fall back to 0 rather
      // than crash the batch fetch. It will simply sort to the back of
      // the "largest first" queue.
      size = 0;
    }
    return CustomAsset(entity: entity, fileSizeBytes: size);
  }

  @override
  bool operator ==(Object other) => other is CustomAsset && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
