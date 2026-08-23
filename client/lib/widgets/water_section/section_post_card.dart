import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../models/post.dart';
import '../../models/user.dart';
import '../../models/water_section.dart';
import '../../providers/auth_provider.dart';
import '../../screens/user_home_screen.dart';
import '../../theme/app_colors.dart';
import '../../utils/app_feedback.dart';
import '../../utils/post_clipboard.dart';
import '../cached_avatar.dart';
import '../post_media/post_media_view.dart';

/// 版块专用帖子卡片。
///
/// 与首页 [PostCard] 完全解耦：
/// - 接受 [section] 参数，不在内部 watch WaterSectionProvider
/// - 展示账号等级 + 版块等级双 badge
/// - 底部操作行改为"分享 / 评论 N / 点赞 N"三段社区风格
/// - 不展示分类 badge、信用分、价格、市场标签
class SectionPostCard extends StatelessWidget {
  final Post post;
  final WaterSection section;
  final Color accentColor;
  final bool? isDark;
  final VoidCallback? onTap;
  final ValueChanged<int>? onAuthorTap;

  const SectionPostCard({
    super.key,
    required this.post,
    required this.section,
    required this.accentColor,
    this.isDark,
    this.onTap,
    this.onAuthorTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = this.isDark ?? (Theme.of(context).brightness == Brightness.dark);
    // 若是当前登录用户，使用最新资料
    final authUser = context.watch<AuthProvider>().user;
    final isMyPost = authUser != null && post.author?.id == authUser.id;
    final displayAvatar =
        isMyPost ? authUser.avatar : (post.author?.avatar ?? '');
    final displayNickname =
        isMyPost ? authUser.nickname : (post.author?.nickname ?? '匿名');

    final validImages =
        post.images.where((img) => img.url.trim().isNotEmpty).toList();
    final imageCount = validImages.length;
    final titleMaxLines = imageCount > 0 ? 1 : 2;
    final contentMaxLines = imageCount >= 2
        ? 1
        : imageCount == 1
            ? 2
            : 3;

    // 标签名：从 section.tags 里查找，不走 provider
    final tagName = _findTagName(post.waterTagId);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: isDark ? AppColors.surfaceSecondaryDark : AppColors.surfaceSecondaryLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isDark
                ? AppColors.borderNormalDark
                : AppColors.borderNormalLight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头像行
              _buildAuthorRow(
                context,
                isDark,
                displayAvatar,
                displayNickname,
                isMyPost ? authUser : post.author,
              ),
              const SizedBox(height: 9),
              // 标题
              if (post.title.isNotEmpty) ...[
                _buildTitleRow(isDark, titleMaxLines),
                const SizedBox(height: 5),
              ],
              // 正文摘要
              if (post.content.isNotEmpty)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => _copyPostContent(context),
                  child: Text(
                    post.content,
                    maxLines: contentMaxLines,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.45,
                      color: isDark
                          ? AppColors.textPrimaryDark
                          : AppColors.textPrimaryLight,
                    ),
                  ),
                ),
              if (post.teamRecruitment != null) ...[
                const SizedBox(height: 9),
                _buildTeamSummary(post.teamRecruitment!, isDark),
              ],
              // 图片区
              if (imageCount > 0) ...[
                const SizedBox(height: 8),
                _buildImageGrid(context, validImages),
              ],
              // 标签行
              if (tagName.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildTagChip(tagName, isDark),
              ],
              const SizedBox(height: 10),
              // 底部操作行
              _buildBottomActions(context, isDark),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTeamSummary(TeamRecruitmentMeta meta, bool isDark) {
    final status = switch (meta.effectiveStatus) {
      'full' => '已满员',
      'closed' => '已关闭',
      'expired' => '已截止',
      _ => '招募中',
    };
    final color = meta.isRecruiting
        ? accentColor
        : (isDark ? Colors.white54 : const Color(0xFF7C8798));
    final roles = meta.roles.length > 2
        ? '${meta.roles.take(2).join(' · ')} · 等 ${meta.roles.length} 个方向'
        : meta.roles.join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.12 : 0.07),
          borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(Icons.groups_2_outlined, size: 16, color: color),
        const SizedBox(width: 6),
        Text(status,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w800, color: color)),
        const SizedBox(width: 8),
        Expanded(
            child: Text('还缺 ${meta.remainingCount} 人 · $roles',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    color: isDark ? Colors.white70 : const Color(0xFF596273)))),
      ]),
    );
  }

  Future<void> _copyPostContent(BuildContext context) async {
    final copied = await PostClipboard.copy(post);
    if (!context.mounted || !copied) return;
    AppFeedback.success('帖子正文已复制', context: context);
  }

  String _findTagName(int? tagId) {
    if (tagId == null || tagId <= 0) return '';
    for (final tag in section.tags) {
      if (tag.id == tagId) return tag.name;
    }
    return '';
  }

  Widget _buildAuthorRow(
    BuildContext context,
    bool isDark,
    String avatar,
    String nickname,
    User? author,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: () => _openAuthor(context, author),
          child: Container(
            padding: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [
                  accentColor,
                  accentColor.withValues(alpha: 0.55),
                ],
              ),
            ),
            child: CachedAvatar(
              radius: 17,
              imageUrl: avatar.isNotEmpty ? ApiConstants.fullUrl(avatar) : null,
              fallbackText: nickname,
            ),
          ),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _openAuthor(context, author),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        nickname,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.15,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    // 版块等级 badge（版块页不展示账号等级）
                    if (post.waterSectionAuthorMeta != null) ...[
                      const SizedBox(width: 4),
                      _buildSectionLevelBadge(post.waterSectionAuthorMeta!),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 1),
              Text(
                _formatTime(post.createdAt),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  color: isDark ? Colors.white38 : const Color(0xFFA0A8B4),
                ),
              ),
            ],
          ),
        ),
        // 精华/置顶 badge（右上角）
        if (post.isFeatured || post.waterSectionFeatured)
          _buildFeaturedBadge(isDark),
        if (post.isActivePinned &&
            !post.isFeatured &&
            !post.waterSectionFeatured)
          _buildPinnedBadge(isDark),
      ],
    );
  }

  Widget _buildSectionLevelBadge(WaterSectionAuthorMeta meta) {
    if (meta.title.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Lv.${meta.level} ${meta.title}',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: accentColor,
          height: 1.1,
        ),
      ),
    );
  }

  Widget _buildTitleRow(bool isDark, int maxLines) {
    return Row(
      children: [
        if (post.isActivePinned) ...[
          _buildSmallBadge('置顶', const Color(0xFFFF4D4F)),
          const SizedBox(width: 5),
        ],
        if (post.isFeatured) ...[
          _buildSmallBadge('精华', const Color(0xFFD97706)),
          const SizedBox(width: 5),
        ] else if (post.waterSectionFeatured) ...[
          _buildSmallBadge('版块精华', const Color(0xFFD97706)),
          const SizedBox(width: 5),
        ],
        Expanded(
          child: Text(
            post.title,
            style: const TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildSmallBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _buildFeaturedBadge(bool isDark) {
    return _buildSmallBadge(
      post.isFeatured ? '精华' : '版块精华',
      const Color(0xFFD97706),
    );
  }

  Widget _buildPinnedBadge(bool isDark) {
    return _buildSmallBadge('置顶', const Color(0xFFFF4D4F));
  }

  Widget _buildTagChip(String tagName, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: isDark ? 0.14 : 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '#$tagName',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: accentColor,
        ),
      ),
    );
  }

  Widget _buildImageGrid(BuildContext context, List<PostImage> images) {
    return PostMediaView(images: images);
  }

  Widget _buildBottomActions(BuildContext context, bool isDark) {
    final mutedColor = isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight;
    return Row(
      children: [
        // 分享
        _buildActionBtn(
          icon: Icons.share_outlined,
          label: '分享',
          color: mutedColor,
          onTap: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('分享功能即将上线')),
            );
          },
        ),
        const Spacer(),
        // 评论
        _buildActionBtn(
          icon: Icons.chat_bubble_outline_rounded,
          label: '评论 ${post.replyCount}',
          color: mutedColor,
          onTap: onTap,
        ),
        const Spacer(),
        // 点赞
        _buildActionBtn(
          icon: post.isLiked
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: '点赞 ${post.likeCount}',
          color: post.isLiked ? const Color(0xFFFF6B6B) : mutedColor,
          onTap: onTap,
        ),
      ],
    );
  }

  Widget _buildActionBtn({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  void _openAuthor(BuildContext context, User? author) {
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

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }
}
