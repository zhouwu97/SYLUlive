import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../models/reply.dart';
import '../../models/user.dart';
import '../../screens/image_viewer_screen.dart';
import '../cached_avatar.dart';
import '../emoji/sticker_catalog.dart';
import '../post_content_link_text.dart';

class PostReplyList extends StatelessWidget {
  const PostReplyList({
    super.key,
    required this.replies,
    required this.onReply,
    this.onAuthorTap,
    this.onMore,
    this.onLongPress,
    this.onLike,
    this.isLikePending,
  });

  final List<Reply> replies;
  final ValueChanged<Reply> onReply;
  final ValueChanged<int>? onAuthorTap;
  final ValueChanged<Reply>? onMore;
  final ValueChanged<Reply>? onLongPress;
  final ValueChanged<Reply>? onLike;
  final bool Function(int replyId)? isLikePending;

  @override
  Widget build(BuildContext context) {
    if (replies.isEmpty) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.chat_bubble_outline,
                size: 36,
                color: isDark ? Colors.white24 : Colors.grey[300],
              ),
              const SizedBox(height: 10),
              Text(
                '还没有评论，来说点什么吧',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white30 : Colors.grey[400],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final childrenByParent = <int, List<Reply>>{};
    for (final reply in replies) {
      final parentId = reply.parentReplyId;
      if (parentId != null) {
        childrenByParent.putIfAbsent(parentId, () => []).add(reply);
      }
    }
    var topLevel =
        replies.where((reply) => reply.parentReplyId == null).toList();
    if (topLevel.isEmpty) topLevel = replies;

    return Column(
      children: [
        for (final reply in topLevel) ...[
          PostReplyItem(
            reply: reply,
            onReply: () => onReply(reply),
            onAuthorTap:
                onAuthorTap == null ? null : () => onAuthorTap!(reply.authorId),
            onMore: onMore == null ? null : () => onMore!(reply),
            onLongPress: onLongPress == null ? null : () => onLongPress!(reply),
            onLike: onLike == null ? null : () => onLike!(reply),
            likePending: isLikePending?.call(reply.id) ?? false,
          ),
          if (childrenByParent[reply.id]?.isNotEmpty == true)
            _ChildReplySummary(
              replies: childrenByParent[reply.id]!,
              onReply: onReply,
            ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class PostReplyItem extends StatelessWidget {
  const PostReplyItem({
    super.key,
    required this.reply,
    required this.onReply,
    this.onAuthorTap,
    this.onMore,
    this.onLongPress,
    this.onStickerLongPress,
    this.onImageLongPress,
    this.onLike,
    this.likePending = false,
  });

  final Reply reply;
  final VoidCallback onReply;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onMore;
  final VoidCallback? onLongPress;
  final ValueChanged<AppSticker>? onStickerLongPress;
  final ValueChanged<String>? onImageLongPress;
  final VoidCallback? onLike;
  final bool likePending;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onReply,
      onLongPress: onLongPress,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: onAuthorTap,
            child: CachedAvatar(
              radius: 18,
              imageUrl: reply.author?.avatar.isNotEmpty == true
                  ? ApiConstants.fullUrl(reply.author!.avatar)
                  : null,
              fallbackText: reply.author?.nickname,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        reply.author?.nickname ?? '匿名',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.82)
                              : Colors.black87,
                        ),
                      ),
                    ),
                    if (reply.author != null) ...[
                      const SizedBox(width: 4),
                      _ReplyLevelBadge(user: reply.author!),
                    ],
                    const SizedBox(width: 8),
                    Text(
                      _formatTime(reply.createdAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white24 : Colors.grey[400],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _ReplyContent(
                  reply: reply,
                  onStickerLongPress: onStickerLongPress,
                  onImageLongPress: onImageLongPress,
                  onTextTap: onReply,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.reply,
                      size: 13,
                      color: isDark ? Colors.white24 : Colors.grey[400],
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '回复',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white24 : Colors.grey[400],
                      ),
                    ),
                    const Spacer(),
                    if (onLike != null)
                      _ReplyLikeButton(
                        reply: reply,
                        pending: likePending,
                        onTap: onLike!,
                      ),
                    if (onMore != null)
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onMore,
                        // 48dp 最小触控目标。
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Icon(
                            Icons.more_horiz,
                            size: 16,
                            color: isDark ? Colors.white24 : Colors.grey[300],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime value) {
    final difference = DateTime.now().difference(value.toLocal());
    if (difference.inMinutes < 1) return '刚刚';
    if (difference.inMinutes < 60) return '${difference.inMinutes}分钟前';
    if (difference.inHours < 24) return '${difference.inHours}小时前';
    if (difference.inDays < 7) return '${difference.inDays}天前';
    return '${value.toLocal().month}/${value.toLocal().day}';
  }
}

class _ReplyContent extends StatelessWidget {
  const _ReplyContent({
    required this.reply,
    this.onStickerLongPress,
    this.onImageLongPress,
    this.onTextTap,
  });

  final Reply reply;
  final ValueChanged<AppSticker>? onStickerLongPress;
  final ValueChanged<String>? onImageLongPress;
  final VoidCallback? onTextTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final content = <Widget>[];
    if (reply.hasTextContent) {
      content.add(
        PostContentLinkText(
          text: reply.content,
          selectable: true,
          onPlainTextTap: onTextTap,
          style: TextStyle(
            fontSize: 14,
            height: 1.55,
            color: isDark ? Colors.white70 : Colors.grey[800],
          ),
        ),
      );
    }
    if (reply.hasSticker) {
      final sticker = appStickerById(reply.stickerId);
      content.add(
        GestureDetector(
          onLongPress: sticker == null || onStickerLongPress == null
              ? null
              : () => onStickerLongPress!(sticker),
          child: CachedNetworkImage(
            key: ValueKey('reply-sticker-${reply.id}'),
            imageUrl: ApiConstants.fullUrl(reply.stickerUrl),
            width: 132,
            height: 132,
            fit: BoxFit.contain,
            placeholder: (_, __) => sticker == null
                ? const SizedBox(
                    width: 132,
                    height: 132,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Image.asset(
                    sticker.thumbnailAsset,
                    width: 132,
                    height: 132,
                    fit: BoxFit.contain,
                  ),
            errorWidget: (_, __, ___) => sticker == null
                ? const SizedBox(
                    width: 132,
                    height: 132,
                    child: Icon(Icons.broken_image_outlined),
                  )
                : Image.asset(
                    sticker.thumbnailAsset,
                    width: 132,
                    height: 132,
                    fit: BoxFit.contain,
                  ),
          ),
        ),
      );
    }

    final imageUrls = reply.images
        .map((image) => image.file?.url.trim() ?? '')
        .where((url) => url.isNotEmpty)
        .map(ApiConstants.fullUrl)
        .toList(growable: false);
    if (imageUrls.isNotEmpty) {
      content.add(
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: List.generate(imageUrls.length, (index) {
            final size = imageUrls.length == 1 ? 190.0 : 88.0;
            return GestureDetector(
              key: ValueKey('reply-image-${reply.id}-$index'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(
                    imageUrls: imageUrls,
                    initialIndex: index,
                  ),
                ),
              ),
              onLongPress: onImageLongPress == null
                  ? null
                  : () => onImageLongPress!(imageUrls[index]),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CachedNetworkImage(
                  imageUrl: imageUrls[index],
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => SizedBox(
                    width: size,
                    height: size,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
            );
          }),
        ),
      );
    }

    if (content.isEmpty) {
      return PostContentLinkText(
        text: reply.content,
        selectable: true,
        onPlainTextTap: onTextTap,
        style: TextStyle(
          fontSize: 14,
          height: 1.55,
          color: isDark ? Colors.white70 : Colors.grey[800],
        ),
      );
    }
    if (content.length == 1) return content.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < content.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          content[index],
        ],
      ],
    );
  }
}

class _ReplyLevelBadge extends StatelessWidget {
  const _ReplyLevelBadge({required this.user});

  final User user;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Color(user.levelColorValue).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        user.levelLabel,
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w700,
          color: Color(user.levelColorValue),
        ),
      ),
    );
  }
}

/// 评论点赞按钮：图标 16px、点击区域 ≥40×40、pending 时禁用连点。
/// 自身拦截点击，绝不触发外层 onReply。
class _ReplyLikeButton extends StatelessWidget {
  const _ReplyLikeButton({
    required this.reply,
    required this.pending,
    required this.onTap,
  });

  final Reply reply;
  final bool pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = reply.isLiked
        ? Theme.of(context).primaryColor
        : (isDark ? Colors.white38 : Colors.grey[400]!);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: pending ? null : onTap,
      child: Padding(
        // 图标 16px，但点击区域通过 Padding 撑到 40×40 以上，方便点按。
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 140),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: Icon(
                reply.isLiked ? Icons.favorite : Icons.favorite_border,
                key: ValueKey('reply-like-icon-${reply.id}-${reply.isLiked}'),
                size: 16,
                color: reply.isLiked
                    ? activeColor
                    : (isDark ? Colors.white38 : Colors.grey[400]),
              ),
            ),
            const SizedBox(width: 4),
            if (reply.likeCount > 0)
              Text(
                '${reply.likeCount}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: reply.isLiked
                      ? activeColor
                      : (isDark ? Colors.white38 : Colors.grey[400]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ChildReplySummary extends StatelessWidget {
  const _ChildReplySummary({
    required this.replies,
    required this.onReply,
  });

  final List<Reply> replies;
  final ValueChanged<Reply> onReply;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final visibleReplies = replies.take(2);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(left: 46, top: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : const Color(0xFFF8F9FA),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final reply in visibleReplies)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onReply(reply),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${reply.author?.nickname ?? '匿名'}：',
                        style: TextStyle(
                          color:
                              isDark ? Colors.white54 : const Color(0xFF6B7280),
                        ),
                      ),
                      TextSpan(
                        text: reply.hasSticker && !reply.hasTextContent
                            ? '[表情]'
                            : reply.content,
                      ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: isDark ? Colors.white60 : const Color(0xFF4B5563),
                  ),
                ),
              ),
            ),
          if (replies.length > 2)
            Text(
              '共 ${replies.length} 条回复',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF6B8EFF),
              ),
            ),
        ],
      ),
    );
  }
}
