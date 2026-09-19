// lib/state/swipe_provider.dart
//
// STATE LAYER — VIEWMODEL
// -------------------------
// This is the "VM" in MVVM. It owns ALL business logic for the swipe
// flow: what's currently queued to view, what's staged for deletion, when
// to fetch the next batch, and how to reconcile a real deletion result
// against the trash buffer. UI widgets are dumb — they read this state
// and dispatch intents (`keep()`, `markForDeletion()`, `emptyTrash()`) but
// contain no decision-making of their own.
//
// Dependency direction: state/ depends on data/ (GalleryService,
// CustomAsset). ui/ depends on state/. Nothing flows backwards.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/custom_asset.dart';
import '../data/services/gallery_service.dart';
import '../data/services/semantic_search_api.dart';

// ---------------------------------------------------------------------
// SERVICE PROVIDERS
// ---------------------------------------------------------------------
// Exposing services as providers (rather than singletons/globals) means
// tests can override them with fakes via `ProviderScope(overrides: [...])`
// without touching any production code.

final galleryServiceProvider = Provider<GalleryService>((ref) {
  return GalleryService();
});

final semanticSearchApiProvider = Provider<SemanticSearchApi>((ref) {
  return SemanticSearchApi();
});

// ---------------------------------------------------------------------
// IMMUTABLE STATE OBJECT
// ---------------------------------------------------------------------

/// Everything the UI needs to render the swipe flow, trash screen, and
/// recap screen. Immutable by convention (`copyWith`) so Riverpod's
/// equality-based rebuild-skipping works correctly.
class SwipeState {
  const SwipeState({
    this.pendingQueue = const [],
    this.trashBuffer = const [],
    this.currentPage = 0,
    this.isLoadingBatch = false,
    this.hasMore = true,
    this.totalAssetCount = 0,
    this.keptCount = 0,
    this.lastEmptiedMegabytes,
    this.errorMessage,
  });

  /// Photos still waiting to be swiped, in largest-first order. The card
  /// at index 0 is the one currently on top of the stack.
  final List<CustomAsset> pendingQueue;

  /// Photos the user swiped left on. They stay on-device until
  /// [SwipeController.emptyTrash] is explicitly called — swiping is
  /// reversible right up until that point.
  final List<CustomAsset> trashBuffer;

  /// Which page of 50 we've fetched up through, for the next
  /// `fetchBatch` call.
  final int currentPage;

  /// True while a background fetch for the next batch is in flight.
  final bool isLoadingBatch;

  /// False once `GalleryService.fetchBatch` returns an empty page —
  /// signals the UI to show an "all done" state instead of a spinner.
  final bool hasMore;

  final int totalAssetCount;

  /// Running count of photos swiped right (kept), used for the gamified
  /// "progress" / streak display.
  final int keptCount;

  /// Set immediately after a successful `emptyTrash()` call so the UI can
  /// navigate to a recap screen showing "You freed X MB!".
  final double? lastEmptiedMegabytes;

  final String? errorMessage;

  /// Total megabytes currently staged in the trash buffer — shown on the
  /// Trash screen before the user commits to deleting.
  double get trashBufferMegabytes =>
      trashBuffer.fold(0.0, (sum, asset) => sum + asset.megabytes);

  SwipeState copyWith({
    List<CustomAsset>? pendingQueue,
    List<CustomAsset>? trashBuffer,
    int? currentPage,
    bool? isLoadingBatch,
    bool? hasMore,
    int? totalAssetCount,
    int? keptCount,
    double? lastEmptiedMegabytes,
    bool clearLastEmptiedMegabytes = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return SwipeState(
      pendingQueue: pendingQueue ?? this.pendingQueue,
      trashBuffer: trashBuffer ?? this.trashBuffer,
      currentPage: currentPage ?? this.currentPage,
      isLoadingBatch: isLoadingBatch ?? this.isLoadingBatch,
      hasMore: hasMore ?? this.hasMore,
      totalAssetCount: totalAssetCount ?? this.totalAssetCount,
      keptCount: keptCount ?? this.keptCount,
      lastEmptiedMegabytes: clearLastEmptiedMegabytes
          ? null
          : (lastEmptiedMegabytes ?? this.lastEmptiedMegabytes),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

// ---------------------------------------------------------------------
// VIEWMODEL (StateNotifier)
// ---------------------------------------------------------------------

class SwipeController extends StateNotifier<SwipeState> {
  SwipeController(this._galleryService) : super(const SwipeState()) {
    // Kick off the very first batch fetch as soon as the controller is
    // created (i.e. as soon as the swipe screen mounts and reads this
    // provider for the first time).
    _initialize();
  }

  final GalleryService _galleryService;

  /// A cap on how many pages we prefetch ahead of the user so the queue
  /// never runs dry mid-swipe, without holding the *entire* gallery in
  /// memory (the whole point of the batching requirement).
  static const int _prefetchThreshold = 10;

  Future<void> _initialize() async {
    try {
      final total = await _galleryService.totalAssetCount();
      state = state.copyWith(totalAssetCount: total);
    } catch (_) {
      // Non-fatal: total count is only used for progress display.
    }
    await loadNextBatch();
  }

  /// Fetches the next page of 50 (largest-first) photos from
  /// [GalleryService] and appends them to the pending queue.
  ///
  /// Guards against duplicate concurrent fetches with [isLoadingBatch],
  /// and against fetching past the end of the library with [hasMore].
  Future<void> loadNextBatch() async {
    if (state.isLoadingBatch || !state.hasMore) return;

    state = state.copyWith(isLoadingBatch: true, clearError: true);

    try {
      final batch = await _galleryService.fetchBatch(state.currentPage);

      state = state.copyWith(
        pendingQueue: [...state.pendingQueue, ...batch],
        currentPage: state.currentPage + 1,
        isLoadingBatch: false,
        hasMore: batch.length == GalleryService.pageSize,
      );
    } catch (e) {
      state = state.copyWith(
        isLoadingBatch: false,
        errorMessage: 'Could not load more photos: $e',
      );
    }
  }

  /// Call this after every swipe so we proactively top up the queue
  /// *before* the user runs out of cards, rather than showing a loading
  /// spinner mid-session.
  void _maybePrefetch() {
    if (state.pendingQueue.length <= _prefetchThreshold && state.hasMore) {
      loadNextBatch();
    }
  }

  /// SWIPE RIGHT — "Keep".
  ///
  /// The photo is simply removed from the pending queue. Nothing is
  /// written to the trash buffer and no native call is made — the photo
  /// remains exactly where it was on disk.
  void keep(CustomAsset asset) {
    state = state.copyWith(
      pendingQueue: state.pendingQueue.where((a) => a.id != asset.id).toList(),
      keptCount: state.keptCount + 1,
    );
    _maybePrefetch();
  }

  /// SWIPE LEFT — "Delete".
  ///
  /// Per the product requirement, this does NOT delete anything yet. The
  /// asset moves from `pendingQueue` into `trashBuffer`, where it sits
  /// until the user visits the Trash screen and explicitly empties it.
  void markForDeletion(CustomAsset asset) {
    state = state.copyWith(
      pendingQueue: state.pendingQueue.where((a) => a.id != asset.id).toList(),
      trashBuffer: [...state.trashBuffer, asset],
    );
    _maybePrefetch();
  }

  /// Lets the user pull a photo back out of the trash buffer from the
  /// Trash screen before committing — the "undo" safety net that makes
  /// swipe-left feel low-stakes.
  void restoreFromTrash(CustomAsset asset) {
    state = state.copyWith(
      trashBuffer: state.trashBuffer.where((a) => a.id != asset.id).toList(),
      // Put it back at the front of the queue so it's the very next card.
      pendingQueue: [asset, ...state.pendingQueue],
    );
  }

  /// THE ACTUAL DELETION.
  ///
  /// Sends every ID currently in `trashBuffer` to `GalleryService`, which
  /// triggers the native (and, on modern OSes, user-confirmed) deletion.
  /// We reconcile the buffer against the IDs the OS actually confirmed
  /// deleting, rather than assuming 100% success, because the user can
  /// cancel the native confirmation dialog.
  ///
  /// Returns the number of megabytes freed, so the caller (Trash screen)
  /// can navigate to the Recap screen with a concrete headline number.
  Future<double> emptyTrash() async {
    if (state.trashBuffer.isEmpty) return 0.0;

    final idsToDelete = state.trashBuffer.map((a) => a.id).toList();
    final deletedIds = await _galleryService.deleteAssets(idsToDelete);
    final deletedIdSet = deletedIds.toSet();

    final actuallyDeleted =
        state.trashBuffer.where((a) => deletedIdSet.contains(a.id));
    final freedMegabytes =
        actuallyDeleted.fold(0.0, (sum, a) => sum + a.megabytes);

    // Anything the OS did NOT confirm deleting (e.g. user cancelled the
    // system dialog) goes back into the pending queue rather than being
    // silently lost from app state.
    final survivors = state.trashBuffer
        .where((a) => !deletedIdSet.contains(a.id))
        .toList();

    state = state.copyWith(
      trashBuffer: survivors,
      pendingQueue: [...survivors, ...state.pendingQueue],
      lastEmptiedMegabytes: freedMegabytes,
    );

    return freedMegabytes;
  }

  void clearRecapFlag() {
    state = state.copyWith(clearLastEmptiedMegabytes: true);
  }
}

/// The single provider the UI layer interacts with.
final swipeControllerProvider =
    StateNotifierProvider<SwipeController, SwipeState>((ref) {
  final galleryService = ref.watch(galleryServiceProvider);
  return SwipeController(galleryService);
});
