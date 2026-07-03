import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/api_constants.dart';
import '../models/post.dart';
import '../screens/image_viewer_screen.dart';
import '../utils/post_image_cache.dart';
import 'cached_avatar.dart';
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171A22) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFE5E7EB),
            ),
            boxShadow: [
              if (!isDark)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (validImages.isNotEmpty)
                _buildCover(context, validImages, 112, 112, isDark,
                    isGrid: false)
              else
                _buildNoImageCover(112, 112, isDark, isGrid: false),
              const SizedBox(width: 12),
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
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                            color:
                                isDark ? Colors.white : const Color(0xFF111827),
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
                            color: isDark
                                ? Colors.white54
                                : const Color(0xFF98A2B3),
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const Spacer(),
                      _buildPriceRow(context, isDark, showViews: true),
                      const SizedBox(height: 6),
                      _buildListUserInfo(context, isDark),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGridCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final validImages =
        post.images.where((img) => img.url.trim().isNotEmpty).toList();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171A22) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFE5E7EB),
            ),
            boxShadow: [
              if (!isDark)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (validImages.isNotEmpty)
                _buildCover(context, validImages, double.infinity, null, isDark,
                    isGrid: true)
              else
                _buildNoImageCover(double.infinity, 0, isDark, isGrid: true),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (post.title.isNotEmpty || post.content.isNotEmpty)
                      Text(
                        post.title.isNotEmpty ? post.title : post.content,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                          color:
                              isDark ? Colors.white : const Color(0xFF111827),
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
        ),
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
          ? const BorderRadius.vertical(top: Radius.circular(16))
          : BorderRadius.circular(12),
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
                    initialIndex: 0,
                  ),
                ),
              );
            },
            child: imageWidget,
          ),
          Positioned(
            left: 6,
            top: 6,
            child: _buildImageBadge(_marketTypeLabel(post)),
          ),
          if (count > 1)
            Positioned(
              right: 6,
              top: 6,
              child: _buildImageBadge('$count图'),
            ),
        ],
      ),
    );
  }

  Widget _buildImageBadge(String label) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildSkeleton(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF242833) : const Color(0xFFF1F3F6),
      child: Center(
        child: Icon(Icons.image_outlined,
            color: isDark ? Colors.white12 : const Color(0xFFC9CED6), size: 28),
      ),
    );
  }

  Widget _buildNoImageCover(double width, double height, bool isDark,
      {required bool isGrid}) {
    final placeholder = Container(
      width: width,
      height: isGrid ? null : height,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF242833) : const Color(0xFFF1F3F6),
        borderRadius: isGrid
            ? const BorderRadius.vertical(top: Radius.circular(16))
            : BorderRadius.circular(12),
      ),
      child: Center(
        child: Icon(
          Icons.image_outlined,
          color: isDark ? Colors.white12 : const Color(0xFFC9CED6),
          size: 28,
        ),
      ),
    );

    if (!isGrid) return placeholder;

    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        children: [
          Positioned.fill(child: placeholder),
          Positioned(
            left: 6,
            top: 6,
            child: _buildImageBadge(_marketTypeLabel(post)),
          ),
        ],
      ),
    );
  }

  Widget _buildPriceRow(BuildContext context, bool isDark,
      {bool showViews = false}) {
    final isLostOrFound = post.postType == 'lost' || post.postType == 'found';
    final isSold = post.status == 'sold' || post.status == 'closed';
    final primaryColor = Theme.of(context).colorScheme.primary;
    final statusLabel = _marketStatusLabel(post);
    final typeLabel = _marketTypeLabel(post);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (!isLostOrFound) ...[
          if (post.price > 0) ...[
            Text(
              '¥',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                color: isSold ? Colors.grey : const Color(0xFFFF5F2E),
              ),
            ),
            Text(
              post.price.toStringAsFixed(
                  post.price.truncateToDouble() == post.price ? 0 : 2),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                height: 1.0,
                color: isSold ? Colors.grey : const Color(0xFFFF5F2E),
              ),
            ),
          ] else ...[
            Text(
              '面议',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w900,
                color: isSold ? Colors.grey : const Color(0xFFFF5F2E),
              ),
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
        if (showViews && post.viewCount > 0) ...[
          const Spacer(),
          Text(
            '${post.viewCount}浏览',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.white38 : const Color(0xFF98A2B3),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildListUserInfo(BuildContext context, bool isDark) {
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
            radius: 8,
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
              style: const TextStyle(
                fontSize: 11,
                color: Color(0xFF8A9099),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        Text(
          _formatTime(post.createdAt),
          style: const TextStyle(
            fontSize: 10,
            color: Color(0xFF8A9099),
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
