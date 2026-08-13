import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../config/api_constants.dart';
import '../../theme/app_motion.dart';
import 'canteen_empty_state.dart';
import 'canteen_theme.dart';

/// 食堂评价区（presentational）。
/// 所有评价状态（sort/filter/data/loading）由父级持有，本组件只渲染并回调。
/// 评价项之间用 divider，不套独立卡片。
class CanteenReviewSection extends StatelessWidget {
  final List<Map<String, dynamic>> reviews;
  final int reviewCount;
  final String sort; // 'best' | 'latest'
  final String filter; // 'all' | 'with_image' | 'high' | 'low'
  final int dataVersion; // 每次成功刷新 +1，作为 AnimatedSwitcher key
  final bool isRefreshing;
  final bool isVoting;
  final int? currentUserId;
  final ValueChanged<String> onSortChanged;
  final ValueChanged<String> onFilterChanged;
  final Future<void> Function(int ratingId, String vote) onVote;
  final VoidCallback onWriteReview;

  const CanteenReviewSection({
    super.key,
    required this.reviews,
    required this.reviewCount,
    required this.sort,
    required this.filter,
    required this.dataVersion,
    required this.isRefreshing,
    required this.isVoting,
    this.currentUserId,
    required this.onSortChanged,
    required this.onFilterChanged,
    required this.onVote,
    required this.onWriteReview,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '用户评价',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '· $reviewCount',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ],
          ),
        ),
        // 综合 / 最新 文字 segmented（underline，无实心 pill）
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Row(
            children: [
              _buildSortOption(isDark, 'best', '综合'),
              const SizedBox(width: 20),
              _buildSortOption(isDark, 'latest', '最新'),
            ],
          ),
        ),
        // Filter chips（轻量：未选中浅灰无边框，选中 accentSoft）
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildFilterChip(isDark, 'all', '全部'),
                const SizedBox(width: 8),
                _buildFilterChip(isDark, 'with_image', '有图'),
                const SizedBox(width: 8),
                _buildFilterChip(isDark, 'high', '高分'),
                const SizedBox(width: 8),
                _buildFilterChip(isDark, 'low', '低分'),
              ],
            ),
          ),
        ),
        // 刷新时评价区顶部 2px 细进度条（绝不整页 loading）。
        // 非刷新态保留 2px 占位高度（不显示条），避免布局跳变。
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: SizedBox(
            height: 2,
            child: isRefreshing
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      color: CanteenTheme.accentColor(isDark),
                      backgroundColor: Colors.transparent,
                    ),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 12),
        // 内容：180ms fade + translateY(4→0)
        AnimatedSwitcher(
          duration: AppMotion.fast,
          switchInCurve: AppMotion.standard,
          switchOutCurve: AppMotion.standard,
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.02),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          child: KeyedSubtree(
            key: ValueKey('reviews-$dataVersion'),
            child: reviews.isEmpty
                ? _buildEmpty(isDark)
                : Column(
                    children: [
                      for (var i = 0; i < reviews.length; i++) ...[
                        if (i > 0)
                          Divider(
                            height: 1,
                            thickness: 0.5,
                            color: CanteenTheme.borderColor(isDark),
                          ),
                        _ReviewItem(
                          review: reviews[i],
                          isDark: isDark,
                          isVoting: isVoting,
                          isOwn:
                              currentUserId != null &&
                                  currentUserId ==
                                      (reviews[i]['user_id'] as num?)?.toInt(),
                          onVote: onVote,
                        ),
                      ],
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildSortOption(bool isDark, String value, String label) {
    final selected = sort == value;
    return GestureDetector(
      onTap: selected ? null : () => onSortChanged(value),
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected
                  ? CanteenTheme.textPrimaryColor(isDark)
                  : CanteenTheme.textSecondaryColor(isDark),
            ),
          ),
          const SizedBox(height: 5),
          AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.standard,
            width: 24,
            height: 2,
            decoration: BoxDecoration(
              color: selected
                  ? CanteenTheme.accentColor(isDark)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(bool isDark, String value, String label) {
    final selected = filter == value;
    return GestureDetector(
      onTap: selected ? null : () => onFilterChanged(value),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? CanteenTheme.accentSoftColor(isDark)
              : CanteenTheme.surfaceMutedBg(isDark),
          borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected
                ? CanteenTheme.accentStrongColor(isDark)
                : CanteenTheme.textSecondaryColor(isDark),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(bool isDark) {
    if (filter != 'all') {
      final (title, subtitle) = switch (filter) {
        'with_image' => (
            '还没有带图评价',
            '这里暂时没有符合条件的内容\n试试切换到「全部」',
          ),
        'high' => ('暂无高分评价', '也许还没有同学给出 4 分以上评价'),
        'low' => ('暂无低分评价', '目前还没有明显踩雷反馈'),
        _ => ('还没有评价', ''),
      };
      return CanteenEmptyState(
        minHeight: 140,
        title: title,
        subtitle: subtitle,
        actionLabel: '查看全部评价',
        onAction: () => onFilterChanged('all'),
      );
    }
    return CanteenEmptyState(
      minHeight: 140,
      title: '还没有同学评价',
      subtitle: '吃过这家？说两句真实体验，给其他同学参考。',
      actionLabel: '写第一条评价',
      onAction: onWriteReview,
    );
  }
}

// ── 单条评价（无卡片，内容 + divider）─────────────────────────────

class _ReviewItem extends StatelessWidget {
  final Map<String, dynamic> review;
  final bool isDark;
  final bool isVoting;
  final bool isOwn;
  final Future<void> Function(int ratingId, String vote) onVote;

  const _ReviewItem({
    required this.review,
    required this.isDark,
    required this.isVoting,
    required this.isOwn,
    required this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    final id = (review['id'] as num?)?.toInt() ?? 0;
    final nickname = review['user_name']?.toString() ?? '匿名同学';
    final content = review['comment']?.toString() ?? '';
    final avatar = review['user_avatar']?.toString() ?? '';
    final rating = (review['star'] as num?)?.toDouble() ?? 0;
    final helpfulCount = (review['helpful_count'] as num?)?.toInt() ?? 0;
    final unhelpfulCount = (review['unhelpful_count'] as num?)?.toInt() ?? 0;
    final myVote = review['my_vote']?.toString();
    final imgList = _parseImageList(review['images']);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.star_rounded,
                size: 14,
                color: CanteenTheme.accentColor(isDark),
              ),
              const SizedBox(width: 4),
              Text(
                rating.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              const Spacer(),
              Text(
                _formatShortDate(review['created_at']?.toString() ?? ''),
                style: TextStyle(
                  fontSize: 12,
                  color: CanteenTheme.textTertiaryColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            content.trim().isNotEmpty
                ? content
                : '这位同学没有留下文字评价',
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w500,
              color: content.trim().isNotEmpty
                  ? CanteenTheme.textPrimaryColor(isDark)
                  : CanteenTheme.textSecondaryColor(isDark),
            ),
          ),
          if (imgList.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: imgList
                  .map(
                    (url) => ClipRRect(
                      borderRadius: BorderRadius.circular(
                        CanteenTheme.radiusSm,
                      ),
                      child: CachedNetworkImage(
                        imageUrl: ApiConstants.fullUrl(url),
                        width: 82,
                        height: 82,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          color: CanteenTheme.surfaceMutedBg(isDark),
                        ),
                        errorWidget: (context, url, error) => Container(
                          color: CanteenTheme.surfaceMutedBg(isDark),
                          child: const Icon(
                            Icons.broken_image,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              _buildSmallAvatar(avatar),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _reviewAuthorText(nickname, review['created_at']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: CanteenTheme.textSecondaryColor(isDark),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (!isOwn) ...[
                _buildVoteButton(
                  icon: Icons.thumb_up_alt_outlined,
                  iconSelected: Icons.thumb_up_alt_rounded,
                  count: helpfulCount,
                  selected: myVote == 'up',
                  onTap: isVoting
                      ? null
                      : () => onVote(id, myVote == 'up' ? 'none' : 'up'),
                ),
                const SizedBox(width: 12),
                _buildVoteButton(
                  icon: Icons.thumb_down_alt_outlined,
                  iconSelected: Icons.thumb_down_alt_rounded,
                  count: unhelpfulCount,
                  selected: myVote == 'down',
                  onTap: isVoting
                      ? null
                      : () => onVote(id, myVote == 'down' ? 'none' : 'down'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSmallAvatar(String avatar) {
    return CircleAvatar(
      radius: 11,
      backgroundColor: CanteenTheme.surfaceMutedBg(isDark),
      backgroundImage: avatar.isNotEmpty
          ? CachedNetworkImageProvider(ApiConstants.fullUrl(avatar))
          : null,
      child: avatar.isEmpty
          ? Icon(
              Icons.person_rounded,
              size: 12,
              color: CanteenTheme.textTertiaryColor(isDark),
            )
          : null,
    );
  }

  Widget _buildVoteButton({
    required IconData icon,
    required IconData iconSelected,
    required int count,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? iconSelected : icon,
              size: 14,
              color: selected
                  ? CanteenTheme.accentColor(isDark)
                  : CanteenTheme.textTertiaryColor(isDark),
            ),
            const SizedBox(width: 3),
            Text(
              count.toString(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected
                    ? CanteenTheme.accentColor(isDark)
                    : CanteenTheme.textTertiaryColor(isDark),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _parseImageList(dynamic rawImages) {
    if (rawImages == null || rawImages.toString().isEmpty) return [];
    try {
      final decoded = jsonDecode(rawImages.toString());
      if (decoded is List) {
        return decoded
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
      }
    } catch (e) {
      // ignore parsing error
    }
    return [];
  }

  String _reviewAuthorText(String nickname, dynamic createdAt) {
    final date = _formatShortDate(createdAt?.toString() ?? '');
    if (date.isEmpty) return nickname;
    return '$nickname · $date';
  }

  String _formatShortDate(String value) {
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return '';
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    return '$month-$day';
  }
}
