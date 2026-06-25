import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import '../../../config/api_constants.dart';
import '../../../models/post.dart';

/// Image grid for publish forms.
///
/// Displays existing (network) and newly selected (local) images in a 3-column
/// square grid.  The first image is tagged with a "封面" (cover) badge.
class PublishImageGrid extends StatelessWidget {
  final List<PostImage> existingImages;
  final List<XFile> selectedImages;
  final bool canAddMore;
  final String addButtonLabel;
  final VoidCallback onAddImage;
  final void Function(int index) onRemoveNewImage;
  final void Function(int index) onRemoveExistingImage;

  const PublishImageGrid({
    super.key,
    required this.existingImages,
    required this.selectedImages,
    required this.canAddMore,
    required this.addButtonLabel,
    required this.onAddImage,
    required this.onRemoveNewImage,
    required this.onRemoveExistingImage,
  });

  int get _totalImages => existingImages.length + selectedImages.length;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ---- 3-column image grid ----
        if (_totalImages > 0)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: _totalImages + (canAddMore ? 1 : 0),
            itemBuilder: (context, index) {
              // "add more" cell
              if (index == _totalImages) {
                return GestureDetector(
                  onTap: onAddImage,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.grey.withValues(alpha: 0.35),
                        width: 1.5,
                        strokeAlign: BorderSide.strokeAlignInside,
                      ),
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.grey.withValues(alpha: 0.06),
                    ),
                    child: Icon(
                      Icons.add,
                      color: Colors.grey.withValues(alpha: 0.6),
                      size: 28,
                    ),
                  ),
                );
              }

              // determine image source
              final isExisting = index < existingImages.length;
              final isFirst = index == 0;

              return Stack(
                fit: StackFit.expand,
                children: [
                  // ---- thumbnail ----
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: isExisting
                        ? CachedNetworkImage(
                            imageUrl:
                                ApiConstants.fullUrl(existingImages[index].url),
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              color: Colors.grey[300],
                              child: const Icon(Icons.broken_image),
                            ),
                          )
                        : Image.file(
                            File(selectedImages[index - existingImages.length]
                                .path),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              color: Colors.grey[300],
                              child: const Icon(Icons.broken_image),
                            ),
                          ),
                  ),

                  // ---- cover badge (first image only) ----
                  if (isFirst)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
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

                  // ---- delete button ----
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
          ),

        const SizedBox(height: 10),

        // ---- add image button (only when no images yet; the grid "+" cell
        //      handles adding when images already exist) ----
        if (_totalImages == 0 && canAddMore)
          OutlinedButton.icon(
            onPressed: onAddImage,
            icon: const Icon(Icons.add_photo_alternate, size: 20),
            label: Text(addButtonLabel, style: const TextStyle(fontSize: 14)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: BorderSide(
                color: Colors.grey.withValues(alpha: 0.35),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
      ],
    );
  }
}
