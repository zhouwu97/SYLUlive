import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/api_constants.dart';
import '../models/post.dart';
import '../utils/post_image_cache.dart';

class PostCard extends StatelessWidget {
  final Post post;
  final VoidCallback? onTap;
  final bool showPrice;
  final bool showWarning;

  const PostCard({
    super.key,
    required this.post,
    this.onTap,
    this.showPrice = false,
    this.showWarning = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : const Color(0xFFE8ECF4),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.04),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [
                            Theme.of(context).primaryColor,
                            Theme.of(context)
                                .primaryColor
                                .withValues(alpha: 0.6),
                          ],
                        ),
                      ),
                      child: CircleAvatar(
                        radius: 18,
                        backgroundImage: post.author?.avatar.isNotEmpty == true
                            ? NetworkImage(
                                ApiConstants.fullUrl(post.author!.avatar),
                              )
                            : null,
                        child: post.author?.avatar.isEmpty == true
                            ? Text(
                                post.author?.nickname
                                        .substring(0, 1)
                                        .toUpperCase() ??
                                    '?',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            post.author?.nickname ?? '匿名',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            _formatTime(post.createdAt),
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.white54 : Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (post.author != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _getCreditColor(post.author!.creditScore)
                              .withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.verified,
                              size: 12,
                              color: _getCreditColor(post.author!.creditScore),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${post.author!.creditScore}%',
                              style: TextStyle(
                                color:
                                    _getCreditColor(post.author!.creditScore),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                if (post.title.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    post.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  post.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black87,
                    height: 1.4,
                  ),
                ),
                if (post.images.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _buildImageGrid(context, post.images),
                ],
                if ((showPrice && post.price > 0) || showWarning) ...[
                  const SizedBox(height: 12),
                  _buildPriceOrWarningTag(context),
                ],
                if (post.postType.isNotEmpty && !showWarning) ...[
                  const SizedBox(height: 8),
                  _buildTypeTag(post.postType),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPriceOrWarningTag(BuildContext context) {
    if (showWarning) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning, color: Colors.red, size: 16),
            const SizedBox(width: 6),
            Text(
              post.price > 0
                  ? '涉案金额 ¥${post.price.toStringAsFixed(0)}'
                  : '曝光举报',
              style: const TextStyle(
                color: Colors.red,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    if (showPrice && post.price > 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Theme.of(context).primaryColor.withValues(alpha: 0.2),
              Theme.of(context).primaryColor.withValues(alpha: 0.1),
            ],
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '¥${post.price.toStringAsFixed(2)}',
          style: TextStyle(
            color: Theme.of(context).primaryColor,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildTypeTag(String type) {
    String label;
    Color color;
    IconData icon;

    switch (type) {
      case 'sell':
        label = '出售';
        color = Colors.green;
        icon = Icons.sell;
        break;
      case 'buy':
        label = '求购';
        color = Colors.orange;
        icon = Icons.shopping_cart;
        break;
      case 'proxy':
        label = '代课';
        color = Colors.blue;
        icon = Icons.school;
        break;
      case 'exposure':
        label = '曝光';
        color = Colors.red;
        icon = Icons.warning;
        break;
      default:
        label = type;
        color = Colors.grey;
        icon = Icons.tag;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageGrid(BuildContext context, List<PostImage> images) {
    final validImages =
        images.where((image) => image.url.trim().isNotEmpty).toList();
    final count = validImages.length;
    if (count == 0) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 200,
        child: count == 1
            ? CachedNetworkImage(
                cacheManager: PostImageCache.manager,
                imageUrl: ApiConstants.fullUrl(validImages[0].url),
                width: double.infinity,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: Colors.grey[300]),
                errorWidget: (_, __, ___) => Container(
                  color: Colors.grey[300],
                  child: const Icon(Icons.image),
                ),
              )
            : GridView.builder(
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: count == 2 ? 2 : 3,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                  childAspectRatio: 1,
                ),
                itemCount: count > 4 ? 4 : count,
                itemBuilder: (context, index) {
                  if (index == 3 && count > 4) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          cacheManager: PostImageCache.manager,
                          imageUrl:
                              ApiConstants.fullUrl(validImages[index].url),
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              Container(color: Colors.grey[300]),
                          errorWidget: (_, __, ___) =>
                              Container(color: Colors.grey[300]),
                        ),
                        Container(
                          color: Colors.black54,
                          alignment: Alignment.center,
                          child: Text(
                            '+${count - 3}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                  return CachedNetworkImage(
                    cacheManager: PostImageCache.manager,
                    imageUrl: ApiConstants.fullUrl(validImages[index].url),
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: Colors.grey[300]),
                    errorWidget: (_, __, ___) => Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.image),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Color _getCreditColor(int score) {
    if (score >= 90) return Colors.green;
    if (score >= 70) return Colors.orange;
    if (score >= 50) return Colors.red;
    return Colors.grey;
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dateTime.month}/${dateTime.day}';
  }
}
