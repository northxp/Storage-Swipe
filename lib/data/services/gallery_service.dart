// lib/data/services/gallery_service.dart
//
// DATA LAYER — SERVICE
// ---------------------
// This is the ONLY file in the whole app that is allowed to talk to
// `photo_manager` directly for reading/deleting photos. Every other layer
// (state/, ui/) depends on this class's public API, never on
// `photo_manager` types beyond the `CustomAsset.entity` handle needed for
// rendering.
//
// Responsibilities:
//   1. Paginated batch fetching (never load the whole gallery into memory).
//   2. Sorting each batch by file size, largest first, so the user clears
//      the biggest storage hogs earliest — this is the core gamification
//      hook ("get the most points/MB for the least swipes").
//   3. Executing native deletion for a batch of asset IDs.

import 'package:photo_manager/photo_manager.dart';
import '../models/custom_asset.dart';

/// Thrown when the device gallery has no accessible photo album at all
/// (e.g. permission was revoked mid-session, or an empty library).
class GalleryUnavailableException implements Exception {
  GalleryUnavailableException(this.message);
  final String message;

  @override
  String toString() => 'GalleryUnavailableException: $message';
}

class GalleryService {
  /// Number of assets fetched per page. Matches the product requirement
  /// of batches of 50 — kept as a named constant so the "why 50" decision
  /// lives in one place and is easy to tune later.
  static const int pageSize = 50;

  /// Cached handle to the root "all photos" album so we don't re-query
  /// `PhotoManager.getAssetPathList` on every single batch fetch.
  AssetPathEntity? _rootAlbum;

  /// Lazily resolves (and caches) the device's root image album.
  ///
  /// `onlyAll: true` collapses iOS's many albums (Recents, Favorites,
  /// per-source albums, etc.) into one synthetic "All Photos" bucket,
  /// which is what we want for a storage-clearing tool — we don't care
  /// about album boundaries, only raw files.
  Future<AssetPathEntity> _getRootAlbum() async {
    if (_rootAlbum != null) return _rootAlbum!;

    final albums = await PhotoManager.getAssetPathList(
      onlyAll: true,
      type: RequestType.image,
    );

    if (albums.isEmpty) {
      throw GalleryUnavailableException(
        'No accessible photo album was found on this device.',
      );
    }

    _rootAlbum = albums.first;
    return _rootAlbum!;
  }

  /// Fetches page [page] (0-indexed) of up to [pageSize] photos, resolves
  /// each one's on-disk byte size, and returns them sorted **descending**
  /// by size — largest (most storage-impactful) files first.
  ///
  /// Runs the size-resolution for the whole page concurrently via
  /// `Future.wait` rather than sequentially, since each call is just an
  /// I/O stat and the platform channel can handle it in parallel.
  Future<List<CustomAsset>> fetchBatch(int page) async {
    final album = await _getRootAlbum();

    final List<AssetEntity> rawAssets = await album.getAssetListPaged(
      page: page,
      size: pageSize,
    );

    if (rawAssets.isEmpty) return const [];

    final List<CustomAsset> resolved = await Future.wait(
      rawAssets.map(CustomAsset.fromEntity),
    );

    // Largest-first sort — this is the "big wins first" gamification hook.
    resolved.sort((a, b) => b.fileSizeBytes.compareTo(a.fileSizeBytes));

    return resolved;
  }

  /// Total number of photos available, used by the UI to show progress
  /// ("Cleared 120 of 1,400 photos") and to know when pagination has
  /// exhausted the library.
  Future<int> totalAssetCount() async {
    final album = await _getRootAlbum();
    return album.assetCountAsync;
  }

  /// Clears the cached root album handle.
  ///
  /// The empty-library UI state offers a "Recheck" action for exactly
  /// the case this method exists for: the user initially had zero
  /// photos (or had denied permission) and has since added photos or
  /// granted access. Without this, `_getRootAlbum` would keep returning
  /// its first, stale lookup for the lifetime of the service instance.
  void invalidateCache() {
    _rootAlbum = null;
  }

  /// Executes the actual, irreversible native deletion for a batch of
  /// asset IDs. This is only ever invoked from the Trash screen's
  /// "Empty Trash" action — never automatically on swipe — matching the
  /// product requirement that swiping left only *stages* a deletion.
  ///
  /// Returns the list of asset IDs the OS confirmed were deleted. On iOS
  /// and Android 11+, this call surfaces a native system confirmation
  /// dialog; if the user cancels that dialog, the returned list may be
  /// empty or partial, so callers should reconcile the trash buffer
  /// against this return value rather than assuming full success.
  Future<List<String>> deleteAssets(List<String> assetIds) async {
    if (assetIds.isEmpty) return const [];
    final result = await PhotoManager.editor.deleteWithIds(assetIds);
    return result;
  }
}
