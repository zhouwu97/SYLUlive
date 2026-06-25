import 'dart:io';
import 'dart:math' show max;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import '../../../config/api_constants.dart';
import '../../../models/post.dart';

/// Image grid for publish forms.
///
/// Displays existing (network) and newly selected (local) images in a 3-column
/// square grid.  The first image is tagged with a "封面" (cover) badge.
/// The grid is always visible — when there are zero images the add cell still
/// renders.
class PublishImageGrid extends StatelessWidget {
  final List<PostImage> existingImages;
  final List<XFile> selectedImages;
  final bool canAddMore;
  final VoidCallback onAddImage;
  final void Function(int index) onRemoveNewImage;
  final void Function(int index) onRemoveExistingImage;
  final bool compact;

  const PublishImageGrid({
    super.key,
    required this.existingImages,
    required this.selectedImages,
    required this.canAddMore,
    required this.onAddImage,
    required this.onRemoveNewImage,
    required this.onRemoveExistingImage,
    this.compact = false,
  });

  int get totalImages => existingImages.length + selectedImages.length;

  double get _spacing => compact ? 8.0 : 10.0;
  double get _radius => compact ? 10.0 : 12.0;
  double get _deleteSize => compact ? 20.0 : 24.0;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Always at least 1 cell (the add cell when empty), plus an extra add
    // cell at the end when there are images and room for more.
    final int cellCount =
        max(1, totalImages) + (canAddMore && totalImages > 0 ? 1 : 0);

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: _spacing,
        mainAxisSpacing: _spacing,
      ),
      itemCount: cellCount,
      itemBuilder: (context, index) {
        // ---- add cell (first position when empty, last position when has images) ----
        final isAddSlot = (totalImages == 0) || (index == totalImages);
        if (isAddSlot) {
          return GestureDetector(
            onTap: onAddImage,
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : const Color(0xFFF5F5F8),
                borderRadius: BorderRadius.circular(_radius),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add,
                    size: compact ? 24 : 28,
                    color: Colors.grey.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '添加照片',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        // ---- image thumbnail ----
        final isExisting = index < existingImages.length;
        final isFirst = index == 0;

        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(_radius),
              child: isExisting
                  ? CachedNetworkImage(
                      imageUrl: ApiConstants.fullUrl(existingImages[index].url),
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.broken_image),
                      ),
                    )
                  : Image.file(
                      File(selectedImages[index - existingImages.length].path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.broken_image),
                      ),
                    ),
            ),

            // cover badge
            if (isFirst)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '封面',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),

            // delete button
            Positioned(
              top: 4,
              right: 4,
              child: GestureDetector(
                onTap: () => isExisting
                    ? onRemoveExistingImage(index)
                    : onRemoveNewImage(index - existingImages.length),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
