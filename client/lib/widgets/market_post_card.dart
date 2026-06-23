import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/api_constants.dart';
import '../models/post.dart';
import '../screens/image_viewer_screen.dart';
import '../utils/post_image_cache.dart';
import 'cached_avatar.dart';
import 'glass_container.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../screens/user_home_screen.dart';

class MarketPostCard extends StatelessWidget {
  final Post post;
  final VoidCallback? onTap;
  final bool compact; // If true, it represents Grid mode. If false, List mode.
  final ValueChanged<int>? onAuthorTap;

  const MarketPostCard({
    super.key,
    required this.post,
    this.onTap,
    this.compact = false,
    this.onAuthorTap,
  });

  String _marketTypeLabel(Post post) {
    switch (post.postType) {
      case 'sell':
        return '出售';
      case 'buy':
        return '求购';
      case 'proxy':
        return '代取';
      case 'lost':
        return '寻物';
      case 'found':
        return '招领';
      default:
        return '';
    }
  }

  String? _marketStatusLabel(Post post) {
    if (post.status == 'sold') return '已售出';
    if (post.status == 'closed') return '已结束';
    return post.postType == 'sell' ? '出售中' : null;
  }

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return _buildGridCard(context);
    } else {
      return _buildListCard(context);
    }
  }

  Widget _buildListCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final validImages =
        post.images.where((img) => img.url.trim().isNotEmpty).toList();

    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 12),
      borderRadius: 14,
      blur: 12,
      opacity: 0.85,
      backgroundColor:
          isDark ? const Color(0xE6171A22) : const Color(0xF2FFFFFF),
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.white.withValues(alpha: 0.85),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left Image
            if (validImages.isNotEmpty)
              _buildCover(context, validImages, 112, 112, isDark, isGrid: false)
            else
              _buildNoImageCover(112, 112, isDark),
            const SizedBox(width: 12),
            // Right Text
            Expanded(
              child: SizedBox(
                height: 112,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (post.title.isNotEmpty || post.content.isNotEmpty)
                      Text(
                        post.title.isNotEmpty ? post.title : post.content,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (post.title.isNotEmpty && post.content.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        post.content,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              isDark ? Colors.white60 : const Color(0xFF98A2B3),
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const Spacer(),
                    _buildPriceRow(context, isDark),
                    const SizedBox(height: 6),
                    _buildCompactUserInfo(context, isDark),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGridCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final validImages =
        post.images.where((img) => img.url.trim().isNotEmpty).toList();

    return GlassContainer(
      margin: EdgeInsets.zero,
      borderRadius: 14,
      blur: 12,
      opacity: 0.85,
      backgroundColor:
          isDark ? const Color(0xE6171A22) : const Color(0xF2FFFFFF),
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.white.withValues(alpha: 0.85),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Image
          if (validImages.isNotEmpty)
            _buildCover(context, validImages, double.infinity, null, isDark,
                isGrid: true)
          else
            _buildNoImageCover(double.infinity, 140, isDark),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (post.title.isNotEmpty || post.content.isNotEmpty)
                  Text(
                    post.title.isNotEmpty ? post.title : post.content,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 6),
                _buildPriceRow(context, isDark),
                const SizedBox(height: 8),
                _buildGridUserInfo(context, isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCover(BuildContext context, List<PostImage> images, double width,
      double? height, bool isDark,
      {required bool isGrid}) {
    final count = images.length;
    final imgUrl = ApiConstants.fullUrl(images[0].url);

    Widget imageWidget = CachedNetworkImage(
      cacheManager: PostImageCache.manager,
      imageUrl: imgUrl,
      fit: BoxFit.cover,
      width: width,
      height: height,
      fadeInDuration: const Duration(milliseconds: 200),
      placeholder: (_, __) => _buildSkeleton(isDark),
      errorWidget: (_, __, ___) => _buildSkeleton(isDark),
    );

    if (isGrid) {
      imageWidget = AspectRatio(
        aspectRatio: 1,
        child: imageWidget,
      );
    }

    return ClipRRect(
      borderRadius: isGrid
          ? const BorderRadius.vertical(top: Radius.circular(14))
          : BorderRadius.circular(10),
      child: Stack(
        children: [
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(
                      imageUrls: images
                          .map((img) => ApiConstants.fullUrl(img.url))
                          .toList(),
                      initialIndex: 0),
                ),
              );
            },
            child: imageWidget,
          ),
          if (!isGrid && count > 1)
            Positioned(
              right: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '共 $count 图',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSkeleton(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF2A2A35) : const Color(0xFFF1F3F6),
      child: Center(
        child: Icon(Icons.image_outlined,
            color: isDark ? Colors.white12 : Colors.black12, size: 28),
      ),
    );
  }

  Widget _buildNoImageCover(double width, double height, bool isDark) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A35) : const Color(0xFFF1F3F6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Center(
        child: Icon(Icons.shopping_bag_outlined,
            color: isDark ? Colors.white12 : Colors.black12, size: 32),
      ),
    );
  }

  Widget _buildPriceRow(BuildContext context, bool isDark) {
    final isLostOrFound = post.postType == 'lost' || post.postType == 'found';
    final isSold = post.status == 'sold' || post.status == 'closed';
    final primaryColor = Theme.of(context).colorScheme.primary;
    final statusLabel = _marketStatusLabel(post);
    final typeLabel = _marketTypeLabel(post);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!isLostOrFound) ...[
          if (post.price > 0) ...[
            Text(
              '¥',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: isSold ? Colors.grey : const Color(0xFFFF7452)),
            ),
            const SizedBox(width: 2),
            Text(
              post.price.toStringAsFixed(
                  post.price.truncateToDouble() == post.price ? 0 : 2),
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                  color: isSold ? Colors.grey : const Color(0xFFFF7452)),
            ),
          ] else ...[
            Text(
              '面议',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: isSold ? Colors.grey : const Color(0xFFFF7452)),
            ),
          ],
          const SizedBox(width: 8),
        ],
        if (statusLabel != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: isSold
                  ? Colors.grey.withValues(alpha: 0.1)
                  : const Color(0xFF39A96B).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 10,
                color: isSold ? Colors.grey : const Color(0xFF39A96B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (isLostOrFound && typeLabel.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              typeLabel,
              style: TextStyle(
                fontSize: 10,
                color: primaryColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCompactUserInfo(BuildContext context, bool isDark) {
    final authUser = context.watch<AuthProvider>().user;
    final isMyPost = authUser != null && post.author?.id == authUser.id;
    final displayAvatar =
        isMyPost ? authUser.avatar : (post.author?.avatar ?? '');
    final displayNickname =
        isMyPost ? authUser.nickname : (post.author?.nickname ?? '匿名');

    return Row(
      children: [
        GestureDetector(
          onTap: () => _openAuthor(context),
          child: CachedAvatar(
            radius: 9,
            imageUrl: displayAvatar.isNotEmpty
                ? ApiConstants.fullUrl(displayAvatar)
                : null,
            fallbackText: displayNickname,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: GestureDetector(
            onTap: () => _openAuthor(context),
            child: Text(
              displayNickname,
              style: TextStyle(
                fontSize: 11,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        Text(
          _formatTime(post.createdAt),
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
        ),
      ],
    );
  }

  Widget _buildGridUserInfo(BuildContext context, bool isDark) {
    final authUser = context.watch<AuthProvider>().user;
    final isMyPost = authUser != null && post.author?.id == authUser.id;
    final displayAvatar =
        isMyPost ? authUser.avatar : (post.author?.avatar ?? '');
    final displayNickname =
        isMyPost ? authUser.nickname : (post.author?.nickname ?? '匿名');

    return Row(
      children: [
        GestureDetector(
          onTap: () => _openAuthor(context),
          child: CachedAvatar(
            radius: 10,
            imageUrl: displayAvatar.isNotEmpty
                ? ApiConstants.fullUrl(displayAvatar)
                : null,
            fallbackText: displayNickname,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: GestureDetector(
            onTap: () => _openAuthor(context),
            child: Text(
              displayNickname,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  void _openAuthor(BuildContext context) {
    final author = post.author;
    if (author == null) return;
    if (onAuthorTap != null) {
      onAuthorTap!(author.id);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => UserHomeScreen(userId: author.id)),
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
