import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class LocalImageComposerPreview extends StatelessWidget {
  const LocalImageComposerPreview({
    super.key,
    required this.image,
    required this.onRemove,
    this.enabled = true,
  });

  final XFile image;
  final VoidCallback onRemove;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('local-image-composer-preview'),
      height: 76,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.45),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(image.path),
              width: 60,
              height: 60,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(
                width: 60,
                height: 60,
                child: Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              image.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            key: const ValueKey('remove-selected-local-image'),
            tooltip: '移除图片',
            onPressed: enabled ? onRemove : null,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}
