// lib/ui/screens/swipe_screen.dart
//
// UI LAYER — SCREEN (VIEW)
// ---------------------------
// The "V" in MVVM. This widget is intentionally "dumb": it watches
// `swipeControllerProvider` for data, renders it, and forwards user
// gestures back to the controller as intents (`keep`, `markForDeletion`,
// `reviewKeptPhotos`, `applySemanticFilter`, `refreshLibrary`). It
// contains ZERO business logic — no sorting, no size math, no native
// calls, no filtering. If you find yourself writing an `if` statement
// here that decides *what happens* to a photo (rather than *how it
// looks*), that logic belongs in `state/swipe_provider.dart` instead.

import 'package:flutter/material.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/permissions_service.dart';
import '../../core/theme.dart';
import '../../state/swipe_provider.dart';
import '../widgets/action_buttons.dart';
import '../widgets/photo_card.dart';
import 'trash_screen.dart';

class SwipeScreen extends ConsumerStatefulWidget {
  const SwipeScreen({super.key});

  @override
  ConsumerState<SwipeScreen> createState() => _SwipeScreenState();
}

class _SwipeScreenState extends ConsumerState<SwipeScreen> {
  // Owned by the View, not the ViewModel: `CardSwiperController` is a
  // pure animation/gesture controller from the `flutter_card_swiper`
  // package. It has no concept of "keep" or "trash" — it only knows how
  // to animate a card off-screen in a direction. That's a UI concern, so
  // it lives here rather than in `SwipeController`.
  final CardSwiperController _cardController = CardSwiperController();
  final TextEditingController _searchController = TextEditingController();

  GalleryAccessResult? _permissionResult;
  bool _searchExpanded = false;

  @override
  void initState() {
    super.initState();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    final result = await PermissionsService.requestGalleryAccess();
    if (mounted) setState(() => _permissionResult = result);
  }

  @override
  void dispose() {
    _cardController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _submitSearch() {
    final query = _searchController.text;
    ref.read(swipeControllerProvider.notifier).applySemanticFilter(query);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _searchExpanded = false);
    ref.read(swipeControllerProvider.notifier).clearSemanticFilter();
  }

  @override
  Widget build(BuildContext context) {
    if (_permissionResult == null) {
      return const _CenteredMessage(child: CircularProgressIndicator());
    }

    if (_permissionResult == GalleryAccessResult.denied) {
      return _PermissionDeniedView(onRetry: _checkPermission);
    }

    final swipeState = ref.watch(swipeControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_searchExpanded ? '' : 'Swipe & Clear'),
        actions: [
          if (!_searchExpanded)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Search by description (e.g. "mountain treks")',
              onPressed: () => setState(() => _searchExpanded = true),
            ),
          if (_searchExpanded)
            Expanded(
              child: _SemanticSearchField(
                controller: _searchController,
                isSearching: swipeState.isSearching,
                onSubmitted: (_) => _submitSearch(),
                onClear: _clearSearch,
              ),
            ),
          if (!_searchExpanded)
            _TrashIconButton(trashCount: swipeState.trashBuffer.length),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ProgressHeader(
              kept: swipeState.keptCount,
              trashed: swipeState.trashBuffer.length,
              total: swipeState.totalAssetCount,
              isReviewMode: swipeState.isReviewMode,
              semanticQuery: swipeState.semanticQuery,
              onClearFilter: _clearSearch,
            ),
            if (swipeState.errorMessage != null)
              _InlineBanner(message: swipeState.errorMessage!),
            Expanded(
              child: _buildCardArea(context, swipeState),
            ),
            if (!swipeState.isLibraryEmpty && swipeState.pendingQueue.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: ActionButtons(controller: _cardController),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardArea(BuildContext context, SwipeState swipeState) {
    // Case 1: the device gallery has never had anything to show at all —
    // distinct from having reviewed everything (see `isLibraryEmpty`'s
    // docs on `SwipeState`).
    if (swipeState.isLibraryEmpty) {
      return _EmptyLibraryView(
        onRecheck: () => ref.read(swipeControllerProvider.notifier).refreshLibrary(),
        onGoToTrash: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TrashScreen()),
        ),
      );
    }

    if (swipeState.pendingQueue.isEmpty) {
      if (swipeState.isLoadingBatch) {
        return const _InlineCenteredMessage(child: CircularProgressIndicator());
      }

      // Case 2: a semantic filter is active but matched nothing that's
      // currently loaded.
      if (swipeState.semanticQuery != null) {
        return _NoSearchResultsView(
          query: swipeState.semanticQuery!,
          onClear: _clearSearch,
        );
      }

      // Case 3: the queue (original pass or review pass) is fully
      // exhausted — the "All Caught Up!" celebratory state.
      if (swipeState.isQueueExhausted) {
        return _AllCaughtUpView(
          isReviewMode: swipeState.isReviewMode,
          canReviewKeptPhotos:
              ref.read(swipeControllerProvider.notifier).canReviewKeptPhotos,
          onReviewKept: () =>
              ref.read(swipeControllerProvider.notifier).reviewKeptPhotos(),
          onRecheck: () =>
              ref.read(swipeControllerProvider.notifier).refreshLibrary(),
          onGoToTrash: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TrashScreen()),
          ),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: CardSwiper(
        key: ValueKey(swipeState.isReviewMode), // reset swiper state cleanly
                                                  // when entering/leaving a
                                                  // review pass, since the
                                                  // underlying data source
                                                  // changes identity.
        controller: _cardController,
        cardsCount: swipeState.pendingQueue.length,
        // Keeping a couple of cards stacked behind the top one is purely
        // a visual/UX affordance (it reads as "there's more to come") —
        // it is capped so we never try to render more cards than are
        // actually queued.
        numberOfCardsDisplayed:
            swipeState.pendingQueue.length >= 2 ? 2 : swipeState.pendingQueue.length,
        backCardOffset: const Offset(0, 32),
        padding: EdgeInsets.zero,
        onSwipe: (previousIndex, currentIndex, direction) {
          // `previousIndex` identifies which card in the CURRENT queue
          // snapshot was just swiped. We resolve the asset here, in the
          // View, purely to translate a *gesture* into an *intent* call
          // on the controller — the decision about what "swipe left"
          // MEANS (stage for deletion vs. delete immediately) lives
          // entirely in `SwipeController`.
          final asset = swipeState.pendingQueue[previousIndex];
          final controller = ref.read(swipeControllerProvider.notifier);

          if (direction == CardSwiperDirection.right) {
            controller.keep(asset);
          } else if (direction == CardSwiperDirection.left) {
            controller.markForDeletion(asset);
          }
          return true; // allow the swipe animation to complete
        },
        cardBuilder: (context, index, percentX, percentY) {
          return PhotoCard(asset: swipeState.pendingQueue[index]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------
// SEMANTIC SEARCH BAR
// ---------------------------------------------------------------------

class _SemanticSearchField extends StatelessWidget {
  const _SemanticSearchField({
    required this.controller,
    required this.isSearching,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final bool isSearching;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: true,
      style: const TextStyle(color: AppColors.textPrimary),
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: 'Try "mountain treks"…',
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        border: InputBorder.none,
        suffixIcon: isSearching
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                icon: const Icon(Icons.close, color: AppColors.textSecondary),
                onPressed: onClear,
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// PROGRESS HEADER
// ---------------------------------------------------------------------

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({
    required this.kept,
    required this.trashed,
    required this.total,
    required this.isReviewMode,
    required this.semanticQuery,
    required this.onClearFilter,
  });

  final int kept;
  final int trashed;
  final int total;
  final bool isReviewMode;
  final String? semanticQuery;
  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context) {
    final reviewed = kept + trashed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                total > 0 ? '$reviewed of $total reviewed' : 'Loading library…',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              Row(
                children: [
                  const Icon(Icons.favorite, color: AppColors.keep, size: 16),
                  const SizedBox(width: 4),
                  Text('$kept', style: const TextStyle(color: AppColors.keep)),
                  const SizedBox(width: 16),
                  const Icon(Icons.delete, color: AppColors.delete, size: 16),
                  const SizedBox(width: 4),
                  Text('$trashed',
                      style: const TextStyle(color: AppColors.delete)),
                ],
              ),
            ],
          ),
          if (isReviewMode || semanticQuery != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                if (isReviewMode)
                  const Chip(
                    avatar: Icon(Icons.replay, size: 16, color: Colors.white),
                    label: Text('Reviewing kept photos'),
                    backgroundColor: AppColors.primary,
                    labelStyle: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                if (semanticQuery != null)
                  Chip(
                    avatar: const Icon(Icons.filter_alt, size: 16, color: Colors.white),
                    label: Text('"$semanticQuery"'),
                    backgroundColor: AppColors.primary,
                    labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
                    deleteIcon: const Icon(Icons.close, size: 16, color: Colors.white),
                    onDeleted: onClearFilter,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineBanner extends StatelessWidget {
  const _InlineBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.textSecondary.withOpacity(0.3)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
    );
  }
}

class _TrashIconButton extends StatelessWidget {
  const _TrashIconButton({required this.trashCount});

  final int trashCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const TrashScreen()),
            ),
          ),
          if (trashCount > 0)
            Positioned(
              right: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: AppColors.delete,
                  shape: BoxShape.circle,
                ),
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                child: Text(
                  '$trashCount',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// EMPTY / TERMINAL STATES
// ---------------------------------------------------------------------

/// Shown when the device gallery genuinely has zero photos (or the very
/// first page fetch came back empty). Distinct from "you've reviewed
/// everything" — see `SwipeState.isLibraryEmpty`.
class _EmptyLibraryView extends StatelessWidget {
  const _EmptyLibraryView({required this.onRecheck, required this.onGoToTrash});

  final VoidCallback onRecheck;
  final VoidCallback onGoToTrash;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined,
                color: AppColors.textSecondary, size: 72),
            const SizedBox(height: 20),
            const Text(
              "No photos found",
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "Your gallery looks empty from here — nothing to swipe "
              "through just yet.",
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRecheck,
              icon: const Icon(Icons.refresh),
              label: const Text('Recheck Gallery'),
            ),
            TextButton(
              onPressed: onGoToTrash,
              child: const Text('Go to Trash'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown once the active queue (original pass or a review pass) has been
/// fully swiped through — the "All Caught Up!" celebratory state, with a
/// path into a second "Review Kept Photos" pass.
class _AllCaughtUpView extends StatelessWidget {
  const _AllCaughtUpView({
    required this.isReviewMode,
    required this.canReviewKeptPhotos,
    required this.onReviewKept,
    required this.onRecheck,
    required this.onGoToTrash,
  });

  final bool isReviewMode;
  final bool canReviewKeptPhotos;
  final VoidCallback onReviewKept;
  final VoidCallback onRecheck;
  final VoidCallback onGoToTrash;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.celebration, color: AppColors.primary, size: 64),
            const SizedBox(height: 16),
            Text(
              isReviewMode
                  ? "Second pass complete!"
                  : "All Caught Up!",
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              "Don't forget to empty your trash to reclaim space.",
              style: TextStyle(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            if (canReviewKeptPhotos)
              ElevatedButton.icon(
                onPressed: onReviewKept,
                icon: const Icon(Icons.replay),
                label: const Text('Review Kept Photos'),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onRecheck,
              icon: const Icon(Icons.refresh),
              label: const Text('Check for New Photos'),
            ),
            TextButton(
              onPressed: onGoToTrash,
              child: const Text('Go to Trash'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a semantic filter is active but nothing currently loaded
/// matches it.
class _NoSearchResultsView extends StatelessWidget {
  const _NoSearchResultsView({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, color: AppColors.textSecondary, size: 56),
            const SizedBox(height: 16),
            Text(
              'No photos matching "$query" are loaded right now.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: onClear, child: const Text('Clear Search')),
          ],
        ),
      ),
    );
  }
}

/// A centered message used INSIDE the existing Scaffold's body (e.g.
/// while a batch is loading mid-session) — no nested Scaffold, so it
/// doesn't paint over the app bar or bottom action buttons.
class _InlineCenteredMessage extends StatelessWidget {
  const _InlineCenteredMessage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: child,
      ),
    );
  }
}

/// A full-screen centered message with its OWN Scaffold — used only for
/// states that replace the entire screen (e.g. "checking permission…"
/// before the main Scaffold has even been built).
class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: child,
        ),
      ),
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  const _PermissionDeniedView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.photo_library_outlined,
                  size: 64, color: AppColors.textSecondary),
              const SizedBox(height: 16),
              const Text(
                'Storage Swipe needs access to your photo library to help '
                'you find and clear space-hogging photos.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: onRetry,
                child: const Text('Grant Access'),
              ),
              const TextButton(
                onPressed: PermissionsService.openSettings,
                child: Text('Open Settings'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
