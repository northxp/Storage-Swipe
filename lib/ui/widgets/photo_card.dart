// lib/ui/widgets/photo_card.dart
//
// UI LAYER — WIDGET
// -------------------
// A purely presentational widget: given a `CustomAsset`, render it as a
// swipeable card face. It holds NO business logic — it doesn't know what
// happens on swipe, doesn't touch providers, and doesn't call any
// service. That decision-making lives entirely in `swipe_provider.dart`
// and is wired up by `swipe_screen.dart`.
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../core/theme.dart';
import '../../data/models/custom_asset.dart';

class PhotoCard extends StatelessWidget {
  const PhotoCard({super.key, required this.asset});

  final CustomAsset asset;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // AssetEntityImage is provided by `photo_manager` and handles
          // efficiently loading a right-sized thumbnail/preview straight
          // from the native photo library — we never decode full-
          // resolution images just to show them in a swipe stack.
          AssetEntityImage(
            asset.entity,
            isOriginal: false,
            thumbnailSize: const ThumbnailSize.square(1080),
            fit: BoxFit.cover,
            loadingBuilder: (context, child, event) {
              if (event == null) return child;
              return Container(
                color: AppColors.surface,
                child: const Center(
                  child: CircularProgressIndicator(color: AppColors.primary),
                ),
              );
            },
            errorBuilder: (context, error, stack) => Container(
              color: AppColors.surface,
              child: const Center(
                child: Icon(Icons.broken_image_outlined,
                    color: AppColors.textSecondary, size: 48),
              ),
            ),
          ),

          // A bottom gradient scrim + file-size chip. Showing the file
          // size directly on the card is the gamification hook: it makes
          // "this is a 42 MB screenshot you don't need" viscerally
          // obvious in the moment of deciding.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _SizeBadge(label: asset.formattedSize),
                  if (asset.entity.createDateTime.year > 1970)
                    Text(
                      _formatDate(asset.entity.createDateTime),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }
}

class _SizeBadge extends StatelessWidget {
  const _SizeBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(0.85),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}
