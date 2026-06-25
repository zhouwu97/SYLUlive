import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import '../../../config/api_constants.dart';
import '../../../models/post.dart';

/// Pure rendering widget for the publish image section.
///
/// Displays existing (network) and newly selected (local file) images in a
/// horizontal scrollable row.  Includes the "add image" button underneath.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ---- image preview row ----
        if (_totalImages > 0) ...[
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _totalImages + (canAddMore ? 1 : 0),
              itemBuilder: (context, index) {
                // "add more" cell at the end of the row
                if (index == _totalImages) {
                  return GestureDetector(
                    onTap: onAddImage,
                    child: Container(
                      width: 100,
                      height: 100,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey[400]!),
                        color: Colors.grey[100],
                      ),
                      child: Icon(Icons.add, color: Colors.grey[600], size: 32),
                    ),
                  );
                }

                // existing (network) image
                if (index < existingImages.length) {
                  final image = existingImages[index];
                  return Stack(
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CachedNetworkImage(
                            imageUrl: ApiConstants.fullUrl(image.url),
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              color: Colors.grey[300],
                              child: const Icon(Icons.broken_image),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 12,
                        child: GestureDetector(
                          onTap: () => onRemoveExistingImage(index),
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
                }

                // newly selected (local file) image
                final image = selectedImages[index - existingImages.length];
                return Stack(
                  children: [
                    Container(
                      width: 100,
                      height: 100,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          File(image.path),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: Colors.grey[300],
                            child: const Icon(Icons.broken_image),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 12,
                      child: GestureDetector(
                        onTap: () =>
                            onRemoveNewImage(index - existingImages.length),
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
          ),
          const SizedBox(height: 8),
        ],

        // ---- add image button (always visible) ----
        OutlinedButton.icon(
          onPressed: onAddImage,
          icon: const Icon(Icons.add_photo_alternate),
          label: Text(addButtonLabel),
        ),
      ],
    );
  }
}
