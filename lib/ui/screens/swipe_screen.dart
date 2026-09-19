// lib/ui/screens/swipe_screen.dart
//
// UI LAYER — SCREEN (VIEW)
// ---------------------------
// The "V" in MVVM. This widget is intentionally "dumb": it watches
// `swipeControllerProvider` for data, renders it, and forwards user
// gestures back to the controller as intents (`keep`, `markForDeletion`).
// It contains ZERO business logic — no sorting, no size math, no native
// calls. If you find yourself writing an `if` statement here that decides
// *what happens* to a photo (rather than *how it looks*), that logic
// belongs in `state/swipe_provider.dart` instead.

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

  GalleryAccessResult? _permissionResult;

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
    super.dispose();
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
        title: const Text('Swipe & Clear'),
        actions: [
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
            ),
            Expanded(
              child: _buildCardArea(context, swipeState),
            ),
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
    if (swipeState.pendingQueue.isEmpty) {
      if (swipeState.isLoadingBatch) {
        return const _CenteredMessage(child: CircularProgressIndicator());
      }
      if (!swipeState.hasMore) {
        return const _CenteredMessage(
          child: _AllDoneMessage(),
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: CardSwiper(
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

class _ProgressHeader extends StatelessWidget {
  const _ProgressHeader({
    required this.kept,
    required this.trashed,
    required this.total,
  });

  final int kept;
  final int trashed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final reviewed = kept + trashed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Row(
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
              Text('$trashed', style: const TextStyle(color: AppColors.delete)),
            ],
          ),
        ],
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

class _AllDoneMessage extends StatelessWidget {
  const _AllDoneMessage();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.celebration, color: AppColors.primary, size: 64),
        SizedBox(height: 16),
        Text(
          "You've reviewed your entire library!",
          style: TextStyle(color: AppColors.textPrimary, fontSize: 18),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: 8),
        Text(
          "Don't forget to empty your trash to reclaim space.",
          style: TextStyle(color: AppColors.textSecondary),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

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
