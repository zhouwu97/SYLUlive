import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../services/emoji_favorite_service.dart';

class FavoriteImageComposerPreview extends StatelessWidget {
  const FavoriteImageComposerPreview({
    super.key,
    required this.favorite,
    required this.onRemove,
    this.httpHeaders = const <String, String>{},
    this.enabled = true,
  });

  final EmojiFavoriteItem favorite;
  final VoidCallback onRemove;
  final Map<String, String> httpHeaders;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('favorite-image-composer-preview'),
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
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: ApiConstants.fullUrl(favorite.imageUrl ?? ''),
              httpHeaders: httpHeaders,
              width: 60,
              height: 60,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => const SizedBox(
                width: 60,
                height: 60,
                child: Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '收藏图片',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            key: const ValueKey('remove-selected-favorite-image'),
            tooltip: '移除收藏图片',
            onPressed: enabled ? onRemove : null,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }
}
