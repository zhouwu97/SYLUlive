import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/user_home_screen.dart';
import '../utils/image_decode_size.dart';
import '../utils/post_image_cache.dart';
import 'cached_avatar.dart';
import 'post_media/post_media_view.dart';

final class _CardTokens {
  static Color cardBg(bool isDark) =>
      isDark ? const Color(0xFF1E2226) : Colors.white;

  static Color borderColor(bool isDark) =>
      isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFF1E5DC);

  static Color titleColor(bool isDark) =>
      isDark ? Colors.white : const Color(0xFF1F2328);

  static Color subColor(bool isDark) =>
      isDark ? Colors.grey.shade400 : const Color(0xFF747B82);

  static Color accent(bool isDark) =>
      isDark ? const Color(0xFFFFA06D) : const Color(0xFFFF7A45);

  static Color accentSoft(bool isDark) => isDark
      ? const Color(0xFFFFA06D).withValues(alpha: 0.14)
      : const Color(0xFFFFF0E8);

  static Color priceColor(bool _) => const Color(0xFFE76F51);

  static Color skeletonBg(bool isDark) =>
      isDark ? const Color(0xFF242833) : const Color(0xFFF1F3F6);

  static Color skeletonIcon(bool isDark) =>
      isDark ? Colors.white12 : const Color(0xFFC9CED6);

  static const double cardRadius = 18;
}

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
        return '办事';
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

  // ── Compact list card (the main market card) ──────────────────────

  Widget _buildListCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final validImages =
        post.images.where((img) => img.url.trim().isNotEmpty).toList();
    final isSold = post.status == 'sold' || post.status == 'closed';
    final accent = _CardTokens.accent(isDark);
    final title = post.title.isNotEmpty ? post.title : post.content;
    final typeLabel = _marketTypeLabel(post);
    final statusLabel = _marketStatusLabel(post);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(_CardTokens.cardRadius),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _CardTokens.cardBg(isDark),
              borderRadius: BorderRadius.circular(_CardTokens.cardRadius),
              border: Border.all(color: _CardTokens.borderColor(isDark)),
              boxShadow: [
                if (!isDark)
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.025),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: image (96×96, with type badge)
                if (validImages.isNotEmpty)
                  _buildCover(context, validImages, 96, 96, isDark,
                      isGrid: false)
                else
                  _buildNoImageCover(96, 96, isDark, isGrid: false),
                const SizedBox(width: 10),
                // Right: compact info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Row 1: title + time
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                                color: _CardTokens.titleColor(isDark),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatTime(post.createdAt),
                            style: TextStyle(
                              fontSize: 11,
                              color: _CardTokens.subColor(isDark),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Row 2: price + status badge
                      Row(
                        children: [
                          if (post.postType != 'lost' &&
                              post.postType != 'found') ...[
                            if (post.price > 0) ...[
                              Text(
                                '¥',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: isSold
                                      ? _CardTokens.subColor(isDark)
                                      : _CardTokens.priceColor(isDark),
                                ),
                              ),
                              Text(
                                post.price.toStringAsFixed(
                                    post.price.truncateToDouble() == post.price
                                        ? 0
                                        : 2),
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                  height: 1.0,
                                  color: isSold
                                      ? _CardTokens.subColor(isDark)
                                      : _CardTokens.priceColor(isDark),
                                ),
                              ),
                            ] else ...[
                              Text(
                                post.postType == 'buy' ? '求购' : '面议',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: accent,
                                ),
                              ),
                            ],
                            const SizedBox(width: 6),
                          ],
                          if (statusLabel != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: isSold
                                    ? Colors.grey.withValues(alpha: 0.08)
                                    : _CardTokens.accentSoft(isDark),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                statusLabel,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isSold ? Colors.grey : accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (typeLabel.isNotEmpty && statusLabel == null) ...[
                            const SizedBox(width: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              decoration: BoxDecoration(
                                color: _CardTokens.accentSoft(isDark),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                typeLabel,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      // Row 3: tags + user
                      Row(
                        children: [
                          if (post.marketTags.isNotEmpty) ...[
                            Expanded(
                              child: Text(
                                post.marketTags.take(2).join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _CardTokens.subColor(isDark),
                                ),
                              ),
                            ),
                          ] else
                            Expanded(
                              child: _buildUserLine(context, isDark),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUserLine(BuildContext context, bool isDark) {
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
            radius: 7,
            imageUrl: displayAvatar.isNotEmpty
                ? ApiConstants.fullUrl(displayAvatar)
                : null,
            fallbackText: displayNickname,
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: GestureDetector(
            onTap: () => _openAuthor(context),
            child: Text(
              displayNickname,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: _CardTokens.subColor(isDark),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Grid card (unchanged layout, just tokens) ────────────────────

  Widget _buildGridCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final validImages =
        post.images.where((img) => img.url.trim().isNotEmpty).toList();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(_CardTokens.cardRadius),
        onTap: onTap,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: _CardTokens.cardBg(isDark),
            borderRadius: BorderRadius.circular(_CardTokens.cardRadius),
            border: Border.all(color: _CardTokens.borderColor(isDark)),
            boxShadow: [
              if (!isDark)
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
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
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
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
                          color: _CardTokens.titleColor(isDark),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 6),
                    if (post.marketTags.isNotEmpty) ...[
                      _buildMarketTags(context, isDark, maxTags: 2),
                      const SizedBox(height: 6),
                    ],
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

  // ── Cover & helpers ───────────────────────────────────────────────

  Widget _buildCover(BuildContext context, List<PostImage> images, double width,
      double? height, bool isDark,
      {required bool isGrid}) {
    // 封面是列表/网格缩略图，按显示像素挑 thumb 档位；变体未就绪时回退原图。
    final validImagesForCover = images
        .where((image) => image.resolvedOriginUrl.trim().isNotEmpty)
        .toList(growable: false);
    final count = images.length;
    final imageUrls = images
        .where((image) => image.url.trim().isNotEmpty)
        .map((image) => ApiConstants.fullUrl(image.url))
        .toList();
    final cover = validImagesForCover.isEmpty
        ? null
        : _selectCoverResource(
            context, validImagesForCover.first, width, height);
    final imgUrl = imageUrls.isEmpty ? '' : imageUrls[0];

    Widget imageWidget = CachedNetworkImage(
      cacheManager: PostImageCache.manager,
      imageUrl: cover?.url ?? imgUrl,
      fit: BoxFit.cover,
      width: width,
      height: height,
      memCacheWidth: cover?.decodeWidth,
      memCacheHeight: cover?.decodeHeight,
      fadeInDuration: const Duration(milliseconds: 200),
      placeholder: (_, __) => _buildSkeleton(isDark),
      errorWidget: (context, url, error) {
        Future.microtask(() => PostImageCache.manager.removeFile(url));
        return _buildSkeleton(isDark);
      },
    );

    if (isGrid) {
      imageWidget = AspectRatio(aspectRatio: 1, child: imageWidget);
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openImageViewer(context, images, 0),
      child: ClipRRect(
        borderRadius: isGrid
            ? const BorderRadius.vertical(
                top: Radius.circular(_CardTokens.cardRadius))
            : BorderRadius.circular(14),
        child: Stack(
          children: [
            imageWidget,
            Positioned(
              left: 4,
              top: 4,
              child: _buildImageBadge(_marketTypeLabel(post)),
            ),
            if (post.status == 'sold' || post.status == 'closed')
              Positioned(
                right: 4,
                top: 4,
                child: _buildStatusCornerBadge(
                  post.status == 'sold' ? '已售出' : '已结束',
                ),
              )
            else if (count > 1)
              Positioned(
                right: 4,
                top: 4,
                child: _buildImageBadge('$count图'),
              ),
          ],
        ),
      ),
    );
  }

  /// 封面档位选择：列表/网格封面只需要 thumb 档（480 长边）。
  ///
  /// 服务端未生成变体时 [selectImageResource] 会回退原图，不会让封面 404。
  _CoverResource _selectCoverResource(
    BuildContext context,
    PostImage image,
    double width,
    double? height,
  ) {
    final target = calculateImageDecodeTarget(
      logicalSize: Size(width, height ?? width),
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      maxLongEdge: imageThumbLongEdge,
      fallbackLogicalSize: const Size(96, 96),
    );
    final originUrl = ApiConstants.fullUrl(image.resolvedOriginUrl);
    final selection = selectImageResource(
      target: target,
      thumbUrl: ApiConstants.fullUrl(image.resolvedThumbUrl),
      mediumUrl: ApiConstants.fullUrl(image.resolvedMediumUrl),
      originUrl: originUrl,
      isAnimatedGif: originUrl.toLowerCase().split('?').first.endsWith('.gif'),
    );
    return _CoverResource(
      url: selection.url,
      decodeWidth: selection.shouldResize ? target.width : null,
      decodeHeight: selection.shouldResize ? target.height : null,
    );
  }

  Widget _buildImageBadge(String label) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildStatusCornerBadge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildSkeleton(bool isDark) {
    return Container(
      color: _CardTokens.skeletonBg(isDark),
      child: Center(
        child: Icon(Icons.image_outlined,
            color: _CardTokens.skeletonIcon(isDark), size: 24),
      ),
    );
  }

  Widget _buildNoImageCover(double width, double height, bool isDark,
      {required bool isGrid}) {
    final placeholder = Container(
      width: width,
      height: isGrid ? null : height,
      decoration: BoxDecoration(
        color: _CardTokens.skeletonBg(isDark),
        borderRadius: isGrid
            ? const BorderRadius.vertical(
                top: Radius.circular(_CardTokens.cardRadius))
            : BorderRadius.circular(14),
      ),
      child: Center(
        child: Icon(
          _getCategoryIcon(),
          color: _CardTokens.skeletonIcon(isDark),
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
            left: 4,
            top: 4,
            child: _buildImageBadge(_marketTypeLabel(post)),
          ),
        ],
      ),
    );
  }

  IconData _getCategoryIcon() {
    switch (post.postType) {
      case 'sell':
        return Icons.sell_outlined;
      case 'buy':
        return Icons.shopping_cart_outlined;
      case 'proxy':
        return Icons.assignment_outlined;
      case 'lost':
        return Icons.search_off_rounded;
      case 'found':
        return Icons.search_rounded;
      default:
        return Icons.image_outlined;
    }
  }

  Widget _buildPriceRow(BuildContext context, bool isDark,
      {bool showViews = false}) {
    final isLostOrFound = post.postType == 'lost' || post.postType == 'found';
    final isSold = post.status == 'sold' || post.status == 'closed';
    final accent = _CardTokens.accent(isDark);
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
                color: isSold
                    ? _CardTokens.subColor(isDark)
                    : _CardTokens.priceColor(isDark),
              ),
            ),
            Text(
              post.price.toStringAsFixed(
                  post.price.truncateToDouble() == post.price ? 0 : 2),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                height: 1.0,
                color: isSold
                    ? _CardTokens.subColor(isDark)
                    : _CardTokens.priceColor(isDark),
              ),
            ),
          ] else ...[
            Text(
              post.postType == 'buy' ? '求购' : '面议',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: accent,
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
                  : _CardTokens.accentSoft(isDark),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                fontSize: 10,
                color: isSold ? Colors.grey : accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (isLostOrFound && typeLabel.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _CardTokens.accentSoft(isDark),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              typeLabel,
              style: TextStyle(
                fontSize: 10,
                color: accent,
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
              color: _CardTokens.subColor(isDark),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMarketTags(BuildContext context, bool isDark,
      {int maxTags = 2}) {
    final tags = post.marketTags.take(maxTags).toList(growable: false);
    final accent = _CardTokens.accent(isDark);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: tags
          .map(
            (tag) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: _CardTokens.accentSoft(isDark),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.0,
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          )
          .toList(),
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

  void _openImageViewer(
    BuildContext context,
    List<PostImage> images,
    int initialIndex,
  ) {
    if (images.isEmpty) return;
    final items =
        images.map(PostMediaView.viewerItemFor).toList(growable: false);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          items: items,
          initialIndex: initialIndex,
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

/// 封面图片资源选择结果。
class _CoverResource {
  const _CoverResource({
    required this.url,
    required this.decodeWidth,
    required this.decodeHeight,
  });

  final String url;
  final int? decodeWidth;
  final int? decodeHeight;
}
