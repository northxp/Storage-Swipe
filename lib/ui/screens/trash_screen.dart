// lib/ui/screens/trash_screen.dart
//
// UI LAYER — SCREEN (VIEW)
// ---------------------------
// Displays everything currently staged in `trashBuffer` and lets the user
// either restore individual photos or commit to the real, native
// deletion via "Empty Trash". This screen is the one and only place in
// the app where an irreversible destructive action can be triggered —
// which is why it requires an explicit confirmation dialog before
// calling `emptyTrash()`.
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../core/theme.dart';
import '../../data/models/custom_asset.dart';
import '../../state/swipe_provider.dart';
import 'recap_screen.dart';

class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  bool _isDeleting = false;

  Future<void> _confirmAndEmpty(SwipeState state) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Empty Trash?'),
        content: Text(
          'This will permanently delete ${state.trashBuffer.length} '
          'photo(s) and free up approximately '
          '${state.trashBufferMegabytes.toStringAsFixed(1)} MB. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child:
                const Text('Delete', style: TextStyle(color: AppColors.delete)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isDeleting = true);

    // The actual native deletion call — the only line in the entire UI
    // layer that results in bytes being removed from the device.
    final freedMb =
        await ref.read(swipeControllerProvider.notifier).emptyTrash();

    if (!mounted) return;
    setState(() => _isDeleting = false);

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => RecapScreen(freedMegabytes: freedMb)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(swipeControllerProvider);
    final notifier = ref.read(swipeControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Trash')),
      body: state.trashBuffer.isEmpty
          ? const Center(
              child: Text(
                'Your trash is empty.\nSwipe left on some photos to fill it up!',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '${state.trashBuffer.length} photos staged • '
                    '${state.trashBufferMegabytes.toStringAsFixed(1)} MB to free',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: state.trashBuffer.length,
                    itemBuilder: (context, index) {
                      final asset = state.trashBuffer[index];
                      return _TrashThumbnail(
                        asset: asset,
                        onRestore: () => notifier.restoreFromTrash(asset),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed:
                          _isDeleting ? null : () => _confirmAndEmpty(state),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.delete,
                      ),
                      icon: _isDeleting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.delete_forever),
                      label: Text(
                        _isDeleting ? 'Deleting…' : 'Empty Trash',
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _TrashThumbnail extends StatelessWidget {
  const _TrashThumbnail({required this.asset, required this.onRestore});

  final CustomAsset asset;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AssetEntityImage(
            asset.entity,
            isOriginal: false,
            thumbnailSize: const ThumbnailSize.square(300),
            fit: BoxFit.cover,
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: onRestore,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.undo, color: Colors.white, size: 16),
              ),
            ),
          ),
          Positioned(
            left: 4,
            bottom: 4,
            child: Text(
              asset.formattedSize,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                shadows: [Shadow(blurRadius: 4, color: Colors.black)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
