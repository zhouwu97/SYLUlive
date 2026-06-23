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
  final bool compact;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    final authUser = context.watch<AuthProvider>().user;
    final isMyPost = authUser != null && post.author?.id == authUser.id;
    final displayAvatar =
        isMyPost ? authUser.avatar : (post.author?.avatar ?? '');
    final displayNickname =
        isMyPost ? authUser.nickname : (post.author?.nickname ?? '匿名');

    final validImages =
        post.images.where((img) => img.url.trim().isNotEmpty).toList();

    return GlassContainer(
      margin: EdgeInsets.zero,
      borderRadius: 16,
      blur: 12,
      opacity: 0.85,
      backgroundColor:
          isDark ? const Color(0xE6171A22) : const Color(0xF2FFFFFF),
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.white.withValues(alpha: 0.85),
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(context, displayAvatar, displayNickname, isDark),
            if (post.title.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                post.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (post.content.isNotEmpty) ...[
              SizedBox(height: post.title.isNotEmpty ? 4 : 10),
              Text(
                post.content,
                maxLines: compact ? 1 : 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isDark ? Colors.white70 : const Color(0xFF666D7A),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
            if (validImages.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildImageGrid(context, validImages),
            ],
            const SizedBox(height: 12),
            _buildBottomSection(context, isDark, primaryColor),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
      BuildContext context, String avatarUrl, String nickname, bool isDark) {
    final author = post.author;
    final levelText = author?.levelLabel ?? '';
    final creditText = author == null ? null : '信用 ${author.creditScore}%';

    return Row(
      children: [
        GestureDetector(
          onTap: () => _openAuthor(context),
          child: CachedAvatar(
            radius: compact ? 14 : 16,
            imageUrl:
                avatarUrl.isNotEmpty ? ApiConstants.fullUrl(avatarUrl) : null,
            fallbackText: nickname,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: GestureDetector(
                      onTap: () => _openAuthor(context),
                      child: Text(
                        nickname,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: compact ? 13 : 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (author != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Color(author.levelColorValue)
                            .withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        compact
                            ? levelText
                            : (creditText != null
                                ? '$levelText · $creditText'
                                : levelText),
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(author.levelColorValue),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (compact)
                Text(
                  _formatTime(post.createdAt),
                  style: TextStyle(
                      fontSize: 10,
                      color: isDark ? Colors.white38 : const Color(0xFF98A2B3)),
                ),
            ],
          ),
        ),
        if (!compact)
          Text(
            _formatTime(post.createdAt),
            style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white38 : const Color(0xFF98A2B3)),
          ),
      ],
    );
  }

  Widget _buildImageGrid(BuildContext context, List<PostImage> images) {
    final imageUrls =
        images.map((img) => ApiConstants.fullUrl(img.url)).toList();
    final count = imageUrls.length;

    if (compact || count == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: GestureDetector(
          onTap: () => _openImageViewer(context, imageUrls, 0),
          child: AspectRatio(
            aspectRatio: 16 / 10,
            child: CachedNetworkImage(
              cacheManager: PostImageCache.manager,
              imageUrl: imageUrls[0],
              fit: BoxFit.cover,
              placeholder: (_, __) => _buildSkeleton(),
              errorWidget: (_, __, ___) => _buildErrorState(),
            ),
          ),
        ),
      );
    }

    if (count == 2) {
      return Row(
        children: [
          Expanded(child: _buildImageItem(context, imageUrls, 0, 1)),
          const SizedBox(width: 4),
          Expanded(child: _buildImageItem(context, imageUrls, 1, 1)),
        ],
      );
    }

    if (count == 3) {
      return Row(
        children: [
          Expanded(child: _buildImageItem(context, imageUrls, 0, 1)),
          const SizedBox(width: 4),
          Expanded(child: _buildImageItem(context, imageUrls, 1, 1)),
          const SizedBox(width: 4),
          Expanded(child: _buildImageItem(context, imageUrls, 2, 1)),
        ],
      );
    }

    // 4+ images
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildSquareImageCell(context, imageUrls, 0)),
            const SizedBox(width: 4),
            Expanded(child: _buildSquareImageCell(context, imageUrls, 1)),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(child: _buildSquareImageCell(context, imageUrls, 2)),
            const SizedBox(width: 4),
            Expanded(
              child: _buildSquareImageCell(
                context,
                imageUrls,
                3,
                remainingCount: count > 4 ? count - 4 : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSquareImageCell(
      BuildContext context, List<String> urls, int index,
      {int? remainingCount}) {
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: GestureDetector(
              onTap: () => _openImageViewer(context, urls, index),
              child: CachedNetworkImage(
                cacheManager: PostImageCache.manager,
                imageUrl: urls[index],
                fit: BoxFit.cover,
                placeholder: (_, __) => _buildSkeleton(),
                errorWidget: (_, __, ___) => _buildErrorState(),
              ),
            ),
          ),
          if (remainingCount != null && remainingCount > 0)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => _openImageViewer(context, urls, index),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '+$remainingCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImageItem(
      BuildContext context, List<String> urls, int index, double aspectRatio) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: GestureDetector(
        onTap: () => _openImageViewer(context, urls, index),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: CachedNetworkImage(
            cacheManager: PostImageCache.manager,
            imageUrl: urls[index],
            fit: BoxFit.cover,
            placeholder: (_, __) => _buildSkeleton(),
            errorWidget: (_, __, ___) => _buildErrorState(),
          ),
        ),
      ),
    );
  }

  Widget _buildSkeleton() {
    return Container(
      color: const Color(0xFFF1F2F5),
      child: const Center(
        child: Icon(Icons.image_outlined, color: Colors.black12, size: 32),
      ),
    );
  }

  Widget _buildErrorState() {
    return Container(
      color: const Color(0xFFF1F2F5),
      child: const Center(
        child:
            Icon(Icons.broken_image_outlined, color: Colors.black26, size: 32),
      ),
    );
  }

  Widget _buildBottomSection(
      BuildContext context, bool isDark, Color primaryColor) {
    final isLostOrFound = post.postType == 'lost' || post.postType == 'found';
    final statusLabel = _marketStatusLabel(post);
    final isSold = post.status == 'sold' || post.status == 'closed';
    final typeLabel = _marketTypeLabel(post);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!isLostOrFound) ...[
              if (post.price > 0) ...[
                Text(
                  '¥',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: isSold ? Colors.grey : const Color(0xFFFF7452)),
                ),
                Text(
                  post.price.toStringAsFixed(
                      post.price.truncateToDouble() == post.price ? 0 : 2),
                  style: TextStyle(
                      fontSize: 20,
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
                    fontSize: 11,
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
                    fontSize: 11,
                    color: primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.visibility_outlined,
                size: 14,
                color: isDark ? Colors.white30 : const Color(0xFF9AA0AA)),
            const SizedBox(width: 4),
            Text('${post.viewCount}',
                style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white30 : const Color(0xFF9AA0AA))),
            const SizedBox(width: 16),
            Icon(post.isLiked ? Icons.favorite : Icons.favorite_border,
                size: 14,
                color: post.isLiked
                    ? const Color(0xFFFF7452)
                    : (isDark ? Colors.white30 : const Color(0xFF9AA0AA))),
            const SizedBox(width: 4),
            Text('${post.likeCount}',
                style: TextStyle(
                    fontSize: 11,
                    color: post.isLiked
                        ? const Color(0xFFFF7452)
                        : (isDark ? Colors.white30 : const Color(0xFF9AA0AA)))),
            const SizedBox(width: 16),
            Icon(Icons.chat_bubble_outline,
                size: 14,
                color: isDark ? Colors.white30 : const Color(0xFF9AA0AA)),
            const SizedBox(width: 4),
            Text('${post.replyCount}',
                style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white30 : const Color(0xFF9AA0AA))),
          ],
        ),
      ],
    );
  }

  void _openImageViewer(
      BuildContext context, List<String> imageUrls, int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ImageViewerScreen(imageUrls: imageUrls, initialIndex: initialIndex),
      ),
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
