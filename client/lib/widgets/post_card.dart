import 'package:flutter/material.dart';

import '../config/api_constants.dart';
import '../config/water_post_taxonomy.dart';
import '../models/post.dart';
import '../models/water_section.dart';
import '../providers/post_provider.dart';
import '../providers/water_section_provider.dart';
import '../screens/post_detail_screen.dart';
import '../screens/user_home_screen.dart';
import '../utils/app_feedback.dart';
import 'cached_avatar.dart';
import 'glass_container.dart';
import 'post_media/post_media_view.dart';
import 'feed/feed_post_action_menu.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class PostCard extends StatefulWidget {
  final Post post;
  final VoidCallback? onTap;
  final bool showPrice;
  final bool showWarning;
  final bool showCategoryBadge;
  final bool disableAuthorNavigation;
  final ValueChanged<int>? onAuthorTap;

  /// 评论按钮点击回调；为空时默认进入详情并聚焦评论输入框。
  final ValueChanged<Post>? onCommentTap;

  /// 卡片右上角操作菜单回调（FEED-3）。为空时不渲染菜单。
  final ValueChanged<FeedPostAction>? onPostAction;
  final bool allowNotInterested;
  final bool allowHideAuthor;
  final bool allowReport;

  const PostCard({
    super.key,
    required this.post,
    this.onTap,
    this.showPrice = false,
    this.showWarning = false,
    this.showCategoryBadge = true,
    this.disableAuthorNavigation = false,
    this.onAuthorTap,
    this.onCommentTap,
    this.onPostAction,
    this.allowNotInterested = true,
    this.allowHideAuthor = true,
    this.allowReport = true,
  });

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// 帖子状态统一从 Provider 读取；没有 Provider 的独立预览仍回退到入参快照。
  Post _displayPost(BuildContext context) {
    return context.watch<PostProvider?>()?.postFor(widget.post.id) ??
        widget.post;
  }

  Post _readDisplayPost(BuildContext context) {
    return context.read<PostProvider?>()?.postFor(widget.post.id) ??
        widget.post;
  }

  Future<void> _toggleLike() async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      AppFeedback.info('请先登录', context: context);
      return;
    }
    final provider = context.read<PostProvider>();
    final current = _readDisplayPost(context);
    if (provider.isLikePending(current.id)) return;
    await provider.toggleLikeOptimistic(current);
  }

  void _handleCommentTap() {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      AppFeedback.info('请先登录', context: context);
      return;
    }
    final post = _readDisplayPost(context);
    final callback = widget.onCommentTap;
    if (callback != null) {
      callback(post);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PostDetailScreen(
          postId: post.id,
          isMarket: post.boardId == 2,
          initialPost: post,
          focusReplyComposer: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final post = _displayPost(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth > 600;

    // 优先使用当前登录用户的最新资料
    final authUser = context.watch<AuthProvider>().user;
    final isMyPost = authUser != null && post.author?.id == authUser.id;
    final displayAvatar =
        isMyPost ? authUser.avatar : (post.author?.avatar ?? '');
    final displayNickname =
        isMyPost ? authUser.nickname : (post.author?.nickname ?? '匿名');

    // 只统计真正具有有效地址的图片
    final validImageCount =
        post.images.where((image) => image.url.trim().isNotEmpty).length;

    // 有图片时标题统一只显示一行
    final titleMaxLines = validImageCount > 0 ? 1 : 2;

    // 单图正文 1 行，多图正文 2 行，无图保持原来的 4 行
    final contentMaxLines = validImageCount == 1
        ? 1
        : validImageCount > 1
            ? 2
            : 4;

    return GlassContainer(
      margin: EdgeInsets.only(bottom: isDesktop ? 14 : 8),
      borderRadius: isDesktop ? 16 : 12,
      blur: 8,
      opacity: 1,
      backgroundColor: isDark ? const Color(0xE6171B24) : Colors.white,
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.10)
          : const Color(0xFFEEF0F5),
      onTap: widget.onTap,
      child: Padding(
        padding: EdgeInsets.all(isDesktop ? 16 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.disableAuthorNavigation
                      ? null
                      : () => _openAuthor(context),
                  child: Container(
                    padding: EdgeInsets.all(isDesktop ? 2 : 1.5),
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
                      radius: isDesktop ? 20 : 16,
                      imageUrl: displayAvatar.isNotEmpty == true
                          ? ApiConstants.fullUrl(displayAvatar)
                          : null,
                      fallbackText: displayNickname,
                    ),
                  ),
                ),
                SizedBox(width: isDesktop ? 12 : 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.disableAuthorNavigation
                            ? null
                            : () => _openAuthor(context),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                displayNickname,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: isDesktop ? 15 : 12,
                                  height: 1.15,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (post.waterSectionAuthorMeta != null) ...[
                              const SizedBox(width: 4),
                              _buildSectionLevelBadge(
                                  post.waterSectionAuthorMeta!),
                            ],
                          ],
                        ),
                      ),
                      SizedBox(height: isDesktop ? 2 : 0),
                      Text(
                        _formatTime(post.createdAt),
                        style: TextStyle(
                          fontSize: isDesktop ? 12 : 10,
                          height: 1.1,
                          color: isDark ? Colors.white54 : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                ),
                if (post.boardId == 1 && widget.showCategoryBadge)
                  _buildCategoryTag(context, isDark, post),
                if (widget.onPostAction != null) ...[
                  const SizedBox(width: 4),
                  FeedPostActionMenu(
                    isMine: isMyPost,
                    isDark: isDark,
                    onAction: widget.onPostAction!,
                    allowNotInterested: widget.allowNotInterested,
                    allowHideAuthor: widget.allowHideAuthor,
                    allowReport: widget.allowReport,
                  ),
                ],
              ],
            ),
            if (post.title.isNotEmpty) ...[
              SizedBox(height: isDesktop ? 12 : 6),
              Row(
                children: [
                  if (post.isActivePinned) ...[
                    _buildPinnedBadge(isDesktop),
                    const SizedBox(width: 6),
                  ],
                  if (post.isFeatured) ...[
                    _buildFeaturedBadge(isDesktop, label: '精华'),
                    const SizedBox(width: 6),
                  ] else if (post.waterSectionFeatured) ...[
                    _buildFeaturedBadge(isDesktop, label: '版块精华'),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      post.title,
                      style: TextStyle(
                        fontSize: isDesktop ? 17 : 15,
                        fontWeight: FontWeight.bold,
                        height: 1.25,
                      ),
                      maxLines: titleMaxLines,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
            if (post.title.isNotEmpty) SizedBox(height: isDesktop ? 8 : 4),
            Text(
              post.content,
              maxLines: contentMaxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isDark ? Colors.white70 : Colors.black87,
                height: isDesktop ? 1.4 : 1.3,
                fontSize: isDesktop ? 15 : 13,
              ),
            ),
            if (validImageCount > 0) ...[
              SizedBox(height: isDesktop ? 12 : 6),
              _buildImageGrid(context, post.images),
            ],
            if (post.boardId == 1 && !widget.showCategoryBadge) ...[
              const SizedBox(height: 6),
              _buildWaterInlineTag(context, isDark, post),
            ],
            if (post.boardId == 1 && post.waterSectionFeatured) ...[
              const SizedBox(height: 6),
              _buildSectionFeaturedStatus(isDark, post),
            ],
            if ((widget.showPrice && post.price > 0) || widget.showWarning) ...[
              const SizedBox(height: 8),
              _buildPriceOrWarningTag(context, post),
            ],
            if (post.boardId != 1 &&
                post.postType.isNotEmpty &&
                !widget.showWarning) ...[
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

  Widget _buildCategoryTag(BuildContext context, bool isDark, Post post) {
    final labels = _waterLabels(context, post);
    final text = labels.sectionLabel.isNotEmpty && labels.tagLabel.isNotEmpty
        ? '${labels.sectionLabel} · ${labels.tagLabel}'
        : labels.sectionLabel;
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: isDark ? Colors.white70 : const Color(0xFF60646C),
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildWaterInlineTag(BuildContext context, bool isDark, Post post) {
    final tagLabel = _waterLabels(context, post).tagLabel;
    if (tagLabel.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          '#$tagLabel',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white60 : const Color(0xFF60646C),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionFeaturedStatus(bool isDark, Post post) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _buildStatusPill(
          icon: Icons.workspace_premium_rounded,
          label: '已入版块精华',
          color: const Color(0xFFD97706),
          isDark: isDark,
        ),
        if (post.homeFeaturedPending)
          _buildStatusPill(
            icon: Icons.pending_actions_rounded,
            label: '首页推荐待审核',
            color: const Color(0xFF2563EB),
            isDark: isDark,
          ),
      ],
    );
  }

  Widget _buildStatusPill({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  _WaterPostLabels _waterLabels(BuildContext context, Post post) {
    if (post.boardId != 1) return const _WaterPostLabels();
    final provider = context.watch<WaterSectionProvider>();
    final section = provider.getBySlug(post.postType);
    final sectionLabel = section?.title ?? waterCategoryLabelOf(post.postType);
    final tag = _findTag(section, post.waterTagId);
    return _WaterPostLabels(
      sectionLabel: sectionLabel,
      tagLabel: tag?.name ?? '',
    );
  }

  WaterSectionTag? _findTag(WaterSection? section, int? tagId) {
    if (section == null || tagId == null || tagId <= 0) return null;
    for (final tag in section.tags) {
      if (tag.id == tagId) return tag;
    }
    return null;
  }

  Widget _buildPriceOrWarningTag(BuildContext context, Post post) {
    if (widget.showWarning) {
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

    if (widget.showPrice && post.price > 0) {
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
        label = '办事';
        color = Colors.blue;
        icon = Icons.task_alt;
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

  Widget _buildFeaturedBadge(bool isDesktop, {String label = '精华'}) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 7 : 6,
        vertical: isDesktop ? 3 : 2,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFFFB020).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xFFFFB020).withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.workspace_premium_rounded,
            size: isDesktop ? 13 : 11,
            color: const Color(0xFFD97706),
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: isDesktop ? 11 : 10,
              fontWeight: FontWeight.w700,
              color: const Color(0xFFD97706),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPinnedBadge(bool isDesktop) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isDesktop ? 7 : 6,
        vertical: isDesktop ? 3 : 2,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFFF4D4F).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: const Color(0xFFFF4D4F).withValues(alpha: 0.32),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.push_pin_rounded,
            size: isDesktop ? 13 : 11,
            color: const Color(0xFFD92D20),
          ),
          const SizedBox(width: 3),
          Text(
            '置顶',
            style: TextStyle(
              fontSize: isDesktop ? 11 : 10,
              fontWeight: FontWeight.w700,
              color: const Color(0xFFD92D20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageGrid(BuildContext context, List<PostImage> images) {
    return PostMediaView(images: images);
    /*
    final validImages =
        images.where((image) => image.url.trim().isNotEmpty).toList();
    final count = validImages.length;
    if (count == 0) return const SizedBox.shrink();
    final imageUrls =
        validImages.map((image) => ApiConstants.fullUrl(image.url)).toList();

    if (count == 1) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final imageWidth = (constraints.maxWidth * 0.72).clamp(220.0, 300.0);
          final imageHeight = (imageWidth * 0.68).clamp(170.0, 220.0);
          return Align(
            alignment: Alignment.centerLeft,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openImageViewer(context, imageUrls, 0),
                child: SizedBox(
                  width: imageWidth,
                  height: imageHeight,
                  child: CachedNetworkImage(
                    cacheManager: PostImageCache.manager,
                    imageUrl: imageUrls[0],
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: Colors.grey[300]),
                    errorWidget: (context, url, error) {
                      Future.microtask(
                          () => PostImageCache.manager.removeFile(url));
                      return Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.broken_image,
                            color: Colors.grey, size: 32),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: ClipRRect(
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
            itemCount: count > 3 ? 3 : count,
            itemBuilder: (context, index) {
              if (index == 2 && count > 3) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openImageViewer(context, imageUrls, 2),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        cacheManager: PostImageCache.manager,
                        imageUrl: imageUrls[index],
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey[300]),
                        errorWidget: (context, url, error) {
                          Future.microtask(
                              () => PostImageCache.manager.removeFile(url));
                          return Container(color: Colors.grey[300]);
                        },
                      ),
                      Container(
                        color: Colors.black54,
                        alignment: Alignment.center,
                        child: Text(
                          '+${count - 2}',
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
                behavior: HitTestBehavior.opaque,
                onTap: () => _openImageViewer(context, imageUrls, index),
                child: CachedNetworkImage(
                  cacheManager: PostImageCache.manager,
                  imageUrl: imageUrls[index],
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: Colors.grey[300]),
                  errorWidget: (context, url, error) {
                    Future.microtask(
                        () => PostImageCache.manager.removeFile(url));
                    return Container(
                      color: Colors.grey[300],
                      child: const Icon(Icons.broken_image),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    */
  }

  void _openAuthor(BuildContext context) {
    final author = _readDisplayPost(context).author;
    if (author == null) return;
    final handler = widget.onAuthorTap;
    if (handler != null) {
      handler(author.id);
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => UserHomeScreen(userId: author.id)),
    );
  }

  Widget _buildBottomMeta(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final post = _displayPost(context);
    return Row(
      children: [
        Icon(
          Icons.visibility_outlined,
          size: 14,
          color: isDark ? Colors.white30 : Colors.grey[400],
        ),
        const SizedBox(width: 4),
        Text(
          '${post.viewCount}',
          style: TextStyle(
            fontSize: 11,
            color: isDark ? Colors.white30 : Colors.grey[400],
          ),
        ),
        const Spacer(),
        // 点赞：原地点赞，不进入详情
        InkWell(
          key: const ValueKey('post-card-like'),
          borderRadius: BorderRadius.circular(8),
          onTap: _toggleLike,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  post.isLiked ? Icons.thumb_up : Icons.thumb_up_outlined,
                  size: 16,
                  color: post.isLiked
                      ? const Color(0xFFFF6B6B)
                      : (isDark ? Colors.white38 : Colors.grey[500]),
                ),
                const SizedBox(width: 4),
                Text(
                  '${post.likeCount}',
                  style: TextStyle(
                    fontSize: 12,
                    color: post.isLiked
                        ? const Color(0xFFFF6B6B)
                        : (isDark ? Colors.white38 : Colors.grey[500]),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 评论：进入详情并聚焦评论输入框
        InkWell(
          key: const ValueKey('post-card-comment'),
          borderRadius: BorderRadius.circular(8),
          onTap: _handleCommentTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 16,
                  color: isDark ? Colors.white38 : Colors.grey[500],
                ),
                const SizedBox(width: 4),
                Text(
                  '${post.replyCount}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.grey[500],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionLevelBadge(WaterSectionAuthorMeta meta) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 4,
        vertical: 0.5,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF6B8EFF).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        meta.title,
        style: const TextStyle(
          fontSize: 8,
          height: 1.15,
          fontWeight: FontWeight.w700,
          color: Color(0xFF6B8EFF),
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

class _WaterPostLabels {
  final String sectionLabel;
  final String tagLabel;

  const _WaterPostLabels({
    this.sectionLabel = '',
    this.tagLabel = '',
  });
}
