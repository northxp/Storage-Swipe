// lib/ui/widgets/action_buttons.dart
//
// UI LAYER — WIDGET
// -------------------
// Manual "keep" / "delete" buttons that sit below the card stack. These
// exist because relying on gesture-only swiping is bad accessibility and
// bad UX for precision — a big satisfying button beats a fiddly gesture
// for a lot of users. They are wired to the SAME `CardSwiperController`
// the gesture-swiping uses, so pressing "Delete" performs an *actual*
// swipe-left animation (`swipeLeft()`) rather than silently mutating
// state — the animation and the state change always stay in sync because
// they both flow through `flutter_card_swiper`'s `onSwipe` callback.

import 'package:flutter/material.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';
import '../../core/theme.dart';

class ActionButtons extends StatelessWidget {
  const ActionButtons({
    super.key,
    required this.controller,
    this.onUndo,
  });

  final CardSwiperController controller;

  /// Optional undo handler — wired up by the screen if it wants to
  /// support "undo my last swipe" (not part of the core requirements,
  /// but a natural, low-cost gamification addition).
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CircleButton(
          icon: Icons.close_rounded,
          color: AppColors.delete,
          size: 56,
          onTap: () => controller.swipe(CardSwiperDirection.left),
          tooltip: 'Delete (swipe left)',
        ),
        if (onUndo != null)
          _CircleButton(
            icon: Icons.undo_rounded,
            color: AppColors.textSecondary,
            size: 44,
            onTap: onUndo!,
            tooltip: 'Undo last swipe',
          ),
        _CircleButton(
          icon: Icons.favorite_rounded,
          color: AppColors.keep,
          size: 56,
          onTap: () => controller.swipe(CardSwiperDirection.right),
          tooltip: 'Keep (swipe right)',
        ),
      ],
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
    this.size = 56,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.surface,
        shape: const CircleBorder(),
        elevation: 4,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(size * 0.28),
            child: Icon(icon, color: color, size: size * 0.45),
          ),
        ),
      ),
    );
  }
}
