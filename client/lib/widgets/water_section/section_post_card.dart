import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/api_constants.dart';
import '../../models/post.dart';
import '../../models/user.dart';
import '../../models/water_section.dart';
import '../../providers/auth_provider.dart';
import '../../screens/user_home_screen.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/app_feedback.dart';
import '../cached_avatar.dart';
import '../post_media/post_media_view.dart';
import '../topic_chips.dart';

const _ignoredLegacyTopicLabels = {'其他', '其它', '默认', '未分类', '综合'};

/// 版块 Feed 帖子卡片。
///
/// 展示层级、图片、Topic 和互动栏与首页 Feed 保持一致，只额外保留本版等级信息。
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
    final dark = isDark ?? Theme.of(context).brightness == Brightness.dark;
    final authUser = context.watch<AuthProvider>().user;
    final isMine = authUser != null && post.author?.id == authUser.id;
    final author = isMine ? authUser : post.author;
    final avatar = isMine ? authUser.avatar : (post.author?.avatar ?? '');
    final nickname =
        isMine ? authUser.nickname : (post.author?.nickname ?? '匿名');
    final validImages = post.images
        .where((image) => image.resolvedOriginUrl.trim().isNotEmpty)
        .toList(growable: false);
    final rawLegacyTag = _findTagName(post.waterTagId);
    final legacyTag = _ignoredLegacyTopicLabels.contains(rawLegacyTag.trim())
        ? ''
        : rawLegacyTag;
    final secondary =
        dark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    final surface =
        dark ? AppColors.surfaceSecondaryDark : AppColors.surfaceSecondaryLight;
    final border =
        dark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: border.withValues(alpha: dark ? 0.82 : 0.52),
          width: 0.8,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, AppSpacing.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildAuthorRow(
                    context, dark, avatar, nickname, author, secondary),
                if (post.title.trim().isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _buildTitleRow(dark),
                ],
                if (post.content.trim().isNotEmpty) ...[
                  SizedBox(height: post.title.trim().isEmpty ? 0 : 6),
                  Text(
                    post.content,
                    maxLines: validImages.isEmpty ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.feedBody.copyWith(
                      color: dark
                          ? AppColors.textPrimaryDark
                          : const Color(0xFF4E565A),
                    ),
                  ),
                ],
                if (post.teamRecruitment != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _buildTeamSummary(post.teamRecruitment!, dark),
                ],
                if (post.topics.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  PostTopicChips(topics: post.topics),
                ] else if (legacyTag.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  _buildLegacyTopic(legacyTag, dark),
                ],
                if (validImages.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  PostMediaView(
                    images: validImages,
                    variant: PostMediaVariant.sectionFeed,
                    onTap: onTap,
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                _buildBottomActions(context, dark, secondary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAuthorRow(
    BuildContext context,
    bool dark,
    String avatar,
    String nickname,
    User? author,
    Color secondary,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: InkWell(
            onTap: () => _openAuthor(context, author),
            customBorder: const CircleBorder(),
            child: Center(
              child: CachedAvatar(
                radius: 18,
                imageUrl:
                    avatar.isNotEmpty ? ApiConstants.fullUrl(avatar) : null,
                fallbackText: nickname,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: InkWell(
            onTap: () => _openAuthor(context, author),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        nickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (post.waterSectionAuthorMeta != null) ...[
                      const SizedBox(width: AppSpacing.xs),
                      _buildSectionLevelBadge(post.waterSectionAuthorMeta!),
                    ],
                  ],
                ),
                Text(
                  _formatTime(post.createdAt),
                  style: AppTextStyles.feedTime.copyWith(
                    color: dark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiaryLight,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTitleRow(bool dark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (post.isActivePinned) ...[
          _buildSmallBadge('置顶', AppColors.danger),
          const SizedBox(width: AppSpacing.xs),
        ],
        if (post.isFeatured || post.waterSectionFeatured) ...[
          _buildSmallBadge('精华', AppColors.feedFeaturedTextLight),
          const SizedBox(width: AppSpacing.xs),
        ],
        Expanded(
          child: Text(
            post.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.feedTitle.copyWith(
              color:
                  dark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionLevelBadge(WaterSectionAuthorMeta meta) {
    final label = meta.title.isEmpty
        ? 'Lv.${meta.level}'
        : 'Lv.${meta.level} ${meta.title}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: accentColor,
          height: 1.1,
        ),
      ),
    );
  }

  Widget _buildSmallBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _buildLegacyTopic(String tagName, bool dark) {
    return Text(
      '#$tagName',
      style: AppTextStyles.feedTag.copyWith(
        color: dark ? AppColors.textSecondaryDark : AppColors.brandPrimary,
      ),
    );
  }

  Widget _buildTeamSummary(TeamRecruitmentMeta meta, bool dark) {
    final status = switch (meta.effectiveStatus) {
      'full' => '已满员',
      'closed' => '已关闭',
      'expired' => '已截止',
      _ => '招募中',
    };
    final color = meta.isRecruiting
        ? accentColor
        : (dark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight);
    final roles = meta.roles.length > 2
        ? '${meta.roles.take(2).join(' · ')} · 等 ${meta.roles.length} 个方向'
        : meta.roles.join(' · ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.12 : 0.07),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(Icons.groups_2_outlined, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            status,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '还缺 ${meta.remainingCount} 人 · $roles',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: dark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActions(
    BuildContext context,
    bool dark,
    Color secondary,
  ) {
    final muted = dark ? AppColors.iconMutedDark : AppColors.iconMutedLight;
    return Row(
      children: [
        _buildMetric(
            Icons.visibility_outlined, _formatCount(post.viewCount), muted),
        const SizedBox(width: AppSpacing.lg),
        _buildMetric(Icons.chat_bubble_outline_rounded,
            _formatCount(post.replyCount), muted),
        const SizedBox(width: AppSpacing.lg),
        _buildMetric(
          post.isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          _formatCount(post.likeCount),
          post.isLiked ? AppColors.danger : muted,
        ),
        const Spacer(),
        Semantics(
          button: true,
          label: '分享帖子',
          child: InkWell(
            onTap: () => AppFeedback.info('分享功能即将上线', context: context),
            customBorder: const CircleBorder(),
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.ios_share_rounded, size: 18),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMetric(IconData icon, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }

  String _formatCount(int count) => count > 999 ? '999+' : '$count';

  String _findTagName(int? tagId) {
    if (tagId == null || tagId <= 0) return '';
    for (final tag in section.tags) {
      if (tag.id == tagId) return tag.name;
    }
    return '';
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
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day}';
  }
}
