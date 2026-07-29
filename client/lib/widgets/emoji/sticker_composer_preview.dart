import 'package:flutter/material.dart';

import 'sticker_catalog.dart';

class StickerComposerPreview extends StatelessWidget {
  const StickerComposerPreview({
    super.key,
    required this.sticker,
    required this.onRemove,
    this.enabled = true,
  });

  final AppSticker sticker;
  final VoidCallback onRemove;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: const ValueKey('sticker-composer-preview'),
      height: 58,
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      color: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : const Color(0xFFF7F8FA),
      child: Row(
        children: [
          Image.asset(
            sticker.thumbnailAsset,
            width: 46,
            height: 46,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const SizedBox(
              width: 46,
              height: 46,
              child: Icon(Icons.broken_image_outlined, size: 20),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              sticker.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white70 : const Color(0xFF4B5563),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('remove-selected-sticker'),
            tooltip: '移除表情',
            onPressed: enabled ? onRemove : null,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}
