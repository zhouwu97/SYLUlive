import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/api_constants.dart';
import '../models/post.dart';
import '../models/user.dart';
import '../screens/image_viewer_screen.dart';
import '../utils/post_image_cache.dart';
import 'cached_avatar.dart';
import 'glass_container.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

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
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth > 600;

    // 优先使用当前登录用户的最新资料
    final authUser = context.watch<AuthProvider>().user;
    final isMyPost = authUser != null && post.author?.id == authUser.id;
    final displayAvatar = isMyPost ? authUser.avatar : (post.author?.avatar ?? '');
    final displayNickname = isMyPost ? authUser.nickname : (post.author?.nickname ?? '匿名');

    return GlassContainer(
      margin: EdgeInsets.only(bottom: isDesktop ? 16 : 8),
      borderRadius: isDesktop ? 16 : 12,
      blur: 12,
      opacity: 0.85,
      backgroundColor:
          isDark ? const Color(0xE6171B24) : const Color(0xF2FFFFFF),
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.white.withValues(alpha: 0.85),
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(isDesktop ? 16 : 12),
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
                        Theme.of(context).primaryColor.withValues(alpha: 0.6),
                      ],
                    ),
                  ),
                  child: CachedAvatar(
                    radius: isDesktop ? 20 : 18,
                    imageUrl: displayAvatar.isNotEmpty == true
                        ? ApiConstants.fullUrl(displayAvatar)
                        : null,
                    fallbackText: displayNickname,
                  ),
                ),
                SizedBox(width: isDesktop ? 12 : 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              displayNickname,
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: isDesktop ? 15 : 13),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (post.author != null) ...[
                            const SizedBox(width: 4),
                            _buildLevelBadge(post.author!),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatTime(post.createdAt),
                        style: TextStyle(
                          fontSize: isDesktop ? 12 : 11,
                          color: isDark ? Colors.white54 : Colors.grey[700],
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
                        size: isDesktop ? 14 : 12,
                        color: _getCreditColor(post.author!.creditScore),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${post.author!.creditScore}%',
                        style: TextStyle(
                          color: _getCreditColor(post.author!.creditScore),
                          fontSize: isDesktop ? 12 : 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (post.title.isNotEmpty) ...[
              SizedBox(height: isDesktop ? 12 : 8),
              Text(
                post.title,
                style: TextStyle(
                  fontSize: isDesktop ? 17 : 15,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            SizedBox(height: isDesktop ? 8 : 6),
            Text(
              post.content,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black87,
                height: 1.4,
                fontSize: isDesktop ? 15 : 13,
              ),
            ),
            if (post.images.isNotEmpty) ...[
              SizedBox(height: isDesktop ? 12 : 8),
              _buildImageGrid(context, post.images),
            ],
            if ((showPrice && post.price > 0) || showWarning) ...[
              const SizedBox(height: 8),
              _buildPriceOrWarningTag(context),
            ],
            if (post.postType.isNotEmpty && !showWarning) ...[
              const SizedBox(height: 6),
              _buildTypeTag(post.postType),
            ],
            const SizedBox(height: 6),
            _buildBottomMeta(context),
          ],
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
      case 'lost':
        label = '失物';
        color = Colors.deepPurple;
        icon = Icons.search_off_outlined;
        break;
      case 'found':
        label = '招领';
        color = Colors.teal;
        icon = Icons.inventory_2_outlined;
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
    final imageUrls =
        validImages.map((image) => ApiConstants.fullUrl(image.url)).toList();

    if (count == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GestureDetector(
          onTap: () => _openImageViewer(context, imageUrls, 0),
          child: Container(
            height: 220,
            color: Colors.black.withValues(alpha: showPrice ? 0.04 : 0),
            child: CachedNetworkImage(
              cacheManager: PostImageCache.manager,
              imageUrl: imageUrls[0],
              width: double.infinity,
              fit: showPrice ? BoxFit.contain : BoxFit.cover,
              placeholder: (_, __) => Container(color: Colors.grey[300]),
              errorWidget: (_, __, ___) => Container(
                color: Colors.grey[300],
                child: const Icon(Icons.image),
              ),
            ),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: count == 2 ? 2 : 3,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1,
        ),
        itemCount: count > 4 ? 4 : count,
        itemBuilder: (context, index) {
          if (index == 3 && count > 4) {
            return GestureDetector(
              onTap: () => _openImageViewer(context, imageUrls, index),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    cacheManager: PostImageCache.manager,
                    imageUrl: imageUrls[index],
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: Colors.grey[300]),
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
              ),
            );
          }
          return GestureDetector(
            onTap: () => _openImageViewer(context, imageUrls, index),
            child: CachedNetworkImage(
              cacheManager: PostImageCache.manager,
              imageUrl: imageUrls[index],
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: Colors.grey[300]),
              errorWidget: (_, __, ___) => Container(
                color: Colors.grey[300],
                child: const Icon(Icons.image),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openImageViewer(
      BuildContext context, List<String> imageUrls, int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          imageUrls: imageUrls,
          initialIndex: initialIndex,
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

  Widget _buildBottomMeta(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Icon(Icons.visibility_outlined, size: 14,
            color: isDark ? Colors.white30 : Colors.grey[400]),
        const SizedBox(width: 4),
        Text(
          '${post.viewCount}',
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white30 : Colors.grey[400],
          ),
        ),
      ],
    );
  }

  Widget _buildLevelBadge(User user) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Color(user.levelColorValue).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        user.levelLabel,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: Color(user.levelColorValue),
        ),
      ),
    );
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
