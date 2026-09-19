// lib/state/swipe_provider.dart
//
// STATE LAYER — VIEWMODEL
// -------------------------
// This is the "VM" in MVVM. It owns ALL business logic for the swipe
// flow: what's currently queued to view, what's staged for deletion, when
// to fetch the next batch, how to reconcile a real deletion result
// against the trash buffer, how to detect and recover from an empty
// library, how a "review kept photos" second pass works, and how a
// semantic-search query filters the live queue. UI widgets are dumb —
// they read this state and dispatch intents (`keep()`,
// `markForDeletion()`, `emptyTrash()`, `reviewKeptPhotos()`,
// `applySemanticFilter()`) but contain no decision-making of their own.
//
// Dependency direction: state/ depends on data/ (GalleryService,
// SemanticSearchApi, CustomAsset). ui/ depends on state/. Nothing flows
// backwards.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/custom_asset.dart';
import '../data/services/embedding_worker.dart';
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

final embeddingIndexerProvider = Provider<EmbeddingIndexer>((ref) {
  return EmbeddingIndexer();
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
    this.keptHistory = const [],
    this.currentPage = 0,
    this.isLoadingBatch = false,
    this.hasMore = true,
    this.totalAssetCount = 0,
    this.keptCount = 0,
    this.lastEmptiedMegabytes,
    this.errorMessage,
    this.isLibraryEmpty = false,
    this.isReviewMode = false,
    this.semanticQuery,
    this.isSearching = false,
    this.preFilterQueue,
  });

  /// Photos still waiting to be swiped, in largest-first order (or, while
  /// a semantic filter is active, in whatever order the filter preserved
  /// from the underlying queue). The card at index 0 is the one currently
  /// on top of the stack.
  final List<CustomAsset> pendingQueue;

  /// Photos the user swiped left on. They stay on-device until
  /// [SwipeController.emptyTrash] is explicitly called — swiping is
  /// reversible right up until that point.
  final List<CustomAsset> trashBuffer;

  /// Photos swiped right (kept) during the CURRENT pass. Cleared and
  /// reloaded into `pendingQueue` when [SwipeController.reviewKeptPhotos]
  /// starts a second pass, so the user can go back and trim down what
  /// they initially saved.
  final List<CustomAsset> keptHistory;

  /// Which page of 50 we've fetched up through, for the next
  /// `fetchBatch` call. Only relevant to fetching fresh photos from the
  /// device gallery — irrelevant while in review mode.
  final int currentPage;

  /// True while a background fetch for the next batch is in flight.
  final bool isLoadingBatch;

  /// False once `GalleryService.fetchBatch` returns an empty page —
  /// signals the UI to show an "all done" state instead of a spinner.
  final bool hasMore;

  final int totalAssetCount;

  /// Running, lifetime count of photos swiped right (kept) — across the
  /// original pass AND any review passes. Used for the gamified
  /// "progress" / streak display; it's a count of decisions, not of
  /// distinct photos still kept.
  final int keptCount;

  /// Set immediately after a successful `emptyTrash()` call so the UI can
  /// navigate to a recap screen showing "You freed X MB!".
  final double? lastEmptiedMegabytes;

  final String? errorMessage;

  /// True when the device's photo library has been confirmed to contain
  /// zero images — distinct from `pendingQueue` merely being empty
  /// because the user has reviewed everything. Drives the "All Caught
  /// Up!" vs. a genuinely-empty-library UI branch in `SwipeScreen`.
  final bool isLibraryEmpty;

  /// True while the user is taking a second pass over previously-kept
  /// photos via [SwipeController.reviewKeptPhotos]. While true, the
  /// controller does not fetch fresh batches from the device gallery —
  /// the queue is fully sourced from `keptHistory`.
  final bool isReviewMode;

  /// The active semantic search query, or null if no filter is applied.
  final String? semanticQuery;

  /// True while a semantic-filter request is in flight.
  final bool isSearching;

  /// A snapshot of `pendingQueue` taken right before a semantic filter
  /// was applied, so [SwipeController.clearSemanticFilter] can restore
  /// it exactly. Null whenever no filter is active.
  final List<CustomAsset>? preFilterQueue;

  /// Total megabytes currently staged in the trash buffer — shown on the
  /// Trash screen before the user commits to deleting.
  double get trashBufferMegabytes =>
      trashBuffer.fold(0.0, (sum, asset) => sum + asset.megabytes);

  /// True once the current queue has been fully swiped through (no cards
  /// left, nothing left to fetch, and no fetch currently running) — this
  /// is the "you've reached the end" state, which is different from
  /// [isLibraryEmpty] (which means there was never anything to show).
  bool get isQueueExhausted =>
      pendingQueue.isEmpty && !hasMore && !isLoadingBatch && !isLibraryEmpty;

  SwipeState copyWith({
    List<CustomAsset>? pendingQueue,
    List<CustomAsset>? trashBuffer,
    List<CustomAsset>? keptHistory,
    int? currentPage,
    bool? isLoadingBatch,
    bool? hasMore,
    int? totalAssetCount,
    int? keptCount,
    double? lastEmptiedMegabytes,
    bool clearLastEmptiedMegabytes = false,
    String? errorMessage,
    bool clearError = false,
    bool? isLibraryEmpty,
    bool? isReviewMode,
    String? semanticQuery,
    bool clearSemanticQuery = false,
    bool? isSearching,
    List<CustomAsset>? preFilterQueue,
    bool clearPreFilterQueue = false,
  }) {
    return SwipeState(
      pendingQueue: pendingQueue ?? this.pendingQueue,
      trashBuffer: trashBuffer ?? this.trashBuffer,
      keptHistory: keptHistory ?? this.keptHistory,
      currentPage: currentPage ?? this.currentPage,
      isLoadingBatch: isLoadingBatch ?? this.isLoadingBatch,
      hasMore: hasMore ?? this.hasMore,
      totalAssetCount: totalAssetCount ?? this.totalAssetCount,
      keptCount: keptCount ?? this.keptCount,
      lastEmptiedMegabytes: clearLastEmptiedMegabytes
          ? null
          : (lastEmptiedMegabytes ?? this.lastEmptiedMegabytes),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      isLibraryEmpty: isLibraryEmpty ?? this.isLibraryEmpty,
      isReviewMode: isReviewMode ?? this.isReviewMode,
      semanticQuery:
          clearSemanticQuery ? null : (semanticQuery ?? this.semanticQuery),
      isSearching: isSearching ?? this.isSearching,
      preFilterQueue: clearPreFilterQueue
          ? null
          : (preFilterQueue ?? this.preFilterQueue),
    );
  }
}

// ---------------------------------------------------------------------
// VIEWMODEL (StateNotifier)
// ---------------------------------------------------------------------

class SwipeController extends StateNotifier<SwipeState> {
  SwipeController(
    this._galleryService,
    this._semanticSearchApi,
    this._embeddingIndexer,
  ) : super(const SwipeState()) {
    // Kick off the very first batch fetch as soon as the controller is
    // created (i.e. as soon as the swipe screen mounts and reads this
    // provider for the first time).
    _initialize();
  }

  final GalleryService _galleryService;
  final SemanticSearchApi _semanticSearchApi;
  final EmbeddingIndexer _embeddingIndexer;

  /// A cap on how many pages we prefetch ahead of the user so the queue
  /// never runs dry mid-swipe, without holding the *entire* gallery in
  /// memory (the whole point of the batching requirement).
  static const int _prefetchThreshold = 10;

  /// Debounce window used to detect "the user paused" for the background
  /// embedding worker's throttling — see [_registerSwipeActivity] and
  /// `data/services/embedding_worker.dart` for the full explanation.
  static const Duration _swipeIdleWindow = Duration(milliseconds: 800);
  Timer? _idleTimer;
  bool _isUserActivelySwiping = false;

  Future<void> _initialize() async {
    try {
      final total = await _galleryService.totalAssetCount();
      state = state.copyWith(totalAssetCount: total);
    } catch (_) {
      // Non-fatal: total count is only used for progress display.
    }
    await loadNextBatch();
  }

  /// Re-runs the initial load from scratch. Used by the empty-state
  /// "Recheck" button — e.g. the user granted gallery permission after
  /// initially denying it, or added photos to a library that was empty
  /// when the app first launched.
  Future<void> refreshLibrary() async {
    _galleryService.invalidateCache();
    state = const SwipeState();
    await _initialize();
  }

  /// Fetches the next page of 50 (largest-first) photos from
  /// [GalleryService] and appends them to the pending queue.
  ///
  /// Guards against duplicate concurrent fetches with [isLoadingBatch],
  /// against fetching past the end of the library with [hasMore], and
  /// never fetches fresh photos while a review pass or a semantic filter
  /// is active — both of those modes work over an already-resolved
  /// subset of assets, not the live device gallery.
  Future<void> loadNextBatch() async {
    if (state.isLoadingBatch ||
        !state.hasMore ||
        state.isReviewMode ||
        state.semanticQuery != null) {
      return;
    }

    state = state.copyWith(isLoadingBatch: true, clearError: true);

    try {
      final batch = await _galleryService.fetchBatch(state.currentPage);

      final bool exhaustedOnFirstPage =
          state.currentPage == 0 && batch.isEmpty;

      state = state.copyWith(
        pendingQueue: [...state.pendingQueue, ...batch],
        currentPage: state.currentPage + 1,
        isLoadingBatch: false,
        hasMore: batch.length == GalleryService.pageSize,
        // A completely empty first page (regardless of what
        // `totalAssetCount` said) is the authoritative signal that the
        // library truly has nothing to show.
        isLibraryEmpty: exhaustedOnFirstPage,
      );

      // Background, best-effort semantic indexing of the batch we just
      // loaded — fire-and-forget so it never blocks the swipe UI. See
      // `data/services/embedding_worker.dart` for the throttling design.
      if (batch.isNotEmpty) {
        unawaited(_indexBatchInBackground(batch));
      }
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
    if (state.isReviewMode || state.semanticQuery != null) return;
    if (state.pendingQueue.length <= _prefetchThreshold && state.hasMore) {
      loadNextBatch();
    }
  }

  /// SWIPE RIGHT — "Keep".
  ///
  /// The photo is removed from the pending queue and recorded in
  /// `keptHistory`, so it's available later for a "Review Kept Photos"
  /// second pass. No native call is made — the photo remains exactly
  /// where it was on disk.
  void keep(CustomAsset asset) {
    _registerSwipeActivity();
    state = state.copyWith(
      pendingQueue: state.pendingQueue.where((a) => a.id != asset.id).toList(),
      keptHistory: [...state.keptHistory, asset],
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
    _registerSwipeActivity();
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

  // -------------------------------------------------------------------
  // REVIEW-AGAIN LOOP
  // -------------------------------------------------------------------

  /// True when there's at least one previously-kept photo available to
  /// review again. Exposed so the UI can decide whether to show the
  /// "Review Kept Photos" button at all.
  bool get canReviewKeptPhotos => state.keptHistory.isNotEmpty;

  /// Starts a second pass over every photo the user has kept so far in
  /// this session. `keptHistory` becomes the new `pendingQueue` (and is
  /// itself cleared — anything kept *again* during the review pass is
  /// re-added to `keptHistory` by the normal `keep()` path, so a third
  /// pass is always possible). While in review mode, no new batches are
  /// fetched from the device gallery — see [loadNextBatch]'s guard.
  void reviewKeptPhotos() {
    if (state.keptHistory.isEmpty) return;

    state = state.copyWith(
      pendingQueue: List<CustomAsset>.from(state.keptHistory),
      keptHistory: const [],
      isReviewMode: true,
      hasMore: false,
      clearError: true,
    );
  }

  /// Leaves review mode. Called automatically once the review queue is
  /// exhausted, or manually if the user backs out — either way, if the
  /// original device-gallery pagination hadn't finished, this lets fresh
  /// batches resume.
  void exitReviewMode({bool resumeFetchingFreshPhotos = false}) {
    state = state.copyWith(
      isReviewMode: false,
      hasMore: resumeFetchingFreshPhotos ? true : state.hasMore,
    );
  }

  // -------------------------------------------------------------------
  // SEMANTIC SEARCH FILTERING
  // -------------------------------------------------------------------

  /// Filters the live `pendingQueue` down to only the photos matching a
  /// natural-language [query] (e.g. "mountain treks"), by asking
  /// [SemanticSearchApi] for the nearest-neighbor asset IDs and
  /// intersecting them with what's currently loaded.
  ///
  /// A snapshot of the queue as it stood before filtering is kept in
  /// `preFilterQueue` so [clearSemanticFilter] can restore it exactly,
  /// including cards the filter temporarily hid.
  ///
  /// Fails soft: if the backend isn't reachable yet (see
  /// `SemanticSearchApi.semanticFilter`'s fail-soft contract), the queue
  /// is left untouched and `errorMessage` explains why, rather than the
  /// screen going blank.
  Future<void> applySemanticFilter(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      clearSemanticFilter();
      return;
    }

    state = state.copyWith(isSearching: true, clearError: true);

    final results = await _semanticSearchApi.semanticFilter(trimmed);

    if (results.isEmpty) {
      state = state.copyWith(
        isSearching: false,
        semanticQuery: trimmed,
        errorMessage:
            'No matches for "$trimmed" yet — the on-device semantic index '
            'may still be building in the background.',
      );
      return;
    }

    final matchingIds = results.map((r) => r.assetId).toSet();
    // If a filter is already active, always filter from the ORIGINAL
    // unfiltered snapshot, not from an already-filtered queue, so
    // successive searches aren't cumulative/destructive.
    final sourceQueue = state.preFilterQueue ?? state.pendingQueue;
    final filtered =
        sourceQueue.where((asset) => matchingIds.contains(asset.id)).toList();

    state = state.copyWith(
      pendingQueue: filtered,
      preFilterQueue: sourceQueue,
      semanticQuery: trimmed,
      isSearching: false,
    );
  }

  /// Restores `pendingQueue` to whatever it was before a semantic filter
  /// was applied, and clears the active query.
  void clearSemanticFilter() {
    if (state.preFilterQueue == null && state.semanticQuery == null) return;
    state = state.copyWith(
      pendingQueue: state.preFilterQueue ?? state.pendingQueue,
      clearPreFilterQueue: true,
      clearSemanticQuery: true,
      clearError: true,
    );
  }

  // -------------------------------------------------------------------
  // BACKGROUND EMBEDDING INDEXING (throttled)
  // -------------------------------------------------------------------

  /// Marks that the user is actively swiping right now, and arms a timer
  /// that flips back to "idle" after a short pause. The background
  /// embedding worker checks this flag before processing each photo, so
  /// it yields the CPU/GPU to swipe animations while the user is
  /// actively engaged, and resumes the moment they pause to look at a
  /// card — the "Graceful Throttling" behavior described in the README.
  void _registerSwipeActivity() {
    _isUserActivelySwiping = true;
    _idleTimer?.cancel();
    _idleTimer = Timer(_swipeIdleWindow, () {
      _isUserActivelySwiping = false;
    });
  }

  Future<void> _indexBatchInBackground(List<CustomAsset> batch) {
    return _embeddingIndexer.indexBatch(
      batch,
      isUserActivelySwiping: () => _isUserActivelySwiping,
      uploadEmbedding: _semanticSearchApi.uploadEmbedding,
    );
  }

  void clearRecapFlag() {
    state = state.copyWith(clearLastEmptiedMegabytes: true);
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

  @override
  void dispose() {
    _idleTimer?.cancel();
    _embeddingIndexer.dispose();
    super.dispose();
  }
}

/// The single provider the UI layer interacts with.
final swipeControllerProvider =
    StateNotifierProvider<SwipeController, SwipeState>((ref) {
  final galleryService = ref.watch(galleryServiceProvider);
  final semanticSearchApi = ref.watch(semanticSearchApiProvider);
  final embeddingIndexer = ref.watch(embeddingIndexerProvider);
  return SwipeController(galleryService, semanticSearchApi, embeddingIndexer);
});
