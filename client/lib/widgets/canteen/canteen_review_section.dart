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
  final Future<void> Function(int ratingId, String source, String vote) onVote;
  final VoidCallback onWriteReview;
  final bool canWriteReview;
  final int? latestReviewId;
  final VoidCallback? onEditLatestReview;
  final Future<void> Function(int reviewId, String source)? onReport;

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
    this.canWriteReview = true,
    this.latestReviewId,
    this.onEditLatestReview,
    this.onReport,
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
                          isOwn: currentUserId != null &&
                              currentUserId ==
                                  (reviews[i]['user_id'] as num?)?.toInt(),
                          onVote: onVote,
                          onReport: onReport,
                          isLatestV2: latestReviewId != null &&
                              (reviews[i]['review_source']?.toString() ??
                                      (reviews[i]['is_v2'] == true
                                          ? 'v2'
                                          : 'legacy')) ==
                                  'v2' &&
                              (reviews[i]['id'] as num?)?.toInt() ==
                                  latestReviewId,
                          onEditLatestReview: onEditLatestReview,
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
      subtitle: canWriteReview ? '吃过这家？说两句真实体验，给其他同学参考。' : '该店当前已下架，历史评价仅供参考。',
      actionLabel: canWriteReview ? '写第一条评价' : null,
      onAction: canWriteReview ? onWriteReview : null,
    );
  }
}

// ── 单条评价（无卡片，内容 + divider）─────────────────────────────

class _ReviewItem extends StatelessWidget {
  final Map<String, dynamic> review;
  final bool isDark;
  final bool isVoting;
  final bool isOwn;
  final bool isLatestV2;
  final Future<void> Function(int ratingId, String source, String vote) onVote;
  final VoidCallback? onEditLatestReview;
  final Future<void> Function(int reviewId, String source)? onReport;

  const _ReviewItem({
    required this.review,
    required this.isDark,
    required this.isVoting,
    required this.isOwn,
    this.isLatestV2 = false,
    required this.onVote,
    this.onEditLatestReview,
    this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final source = review['review_source']?.toString() ??
        (review['is_v2'] == true ? 'v2' : 'legacy');
    final id = (review['id'] as num?)?.toInt() ?? 0;
    final nickname = review['user_name']?.toString() ?? '匿名同学';
    final content = review['comment']?.toString() ?? '';
    final avatar = review['user_avatar']?.toString() ?? '';
    final rating = (review['star'] as num?)?.toDouble() ?? 0;
    final helpfulCount = (review['helpful_count'] as num?)?.toInt() ?? 0;
    final unhelpfulCount = (review['unhelpful_count'] as num?)?.toInt() ?? 0;
    final myVote = review['my_vote']?.toString();
    final imgList = _parseImageList(review['images']);
    final tagLabels = _parseTagLabels(review['tags']);
    final dishNames = _parseRecommendedDishNames(review);
    final dimensionScores = review['dimension_scores'] is Map
        ? Map<String, dynamic>.from(review['dimension_scores'] as Map)
        : const <String, dynamic>{};

    return Padding(
      key: ValueKey('$source:$id'),
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
          if (dimensionScores.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 5,
              children: [
                _buildDimensionBadge('味道', dimensionScores['taste']),
                _buildDimensionBadge('性价比', dimensionScores['value']),
                _buildDimensionBadge('排队', dimensionScores['queue']),
                _buildDimensionBadge('卫生', dimensionScores['hygiene']),
                _buildDimensionBadge('服务', dimensionScores['service']),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Text(
            content.trim().isNotEmpty ? content : '这位同学没有留下文字评价',
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w500,
              color: content.trim().isNotEmpty
                  ? CanteenTheme.textPrimaryColor(isDark)
                  : CanteenTheme.textSecondaryColor(isDark),
            ),
          ),
          if (tagLabels.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < tagLabels.take(3).length; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: CanteenTheme.surfaceMutedBg(isDark),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tagLabels[i],
                      style: TextStyle(
                        fontSize: 11,
                        color: CanteenTheme.textSecondaryColor(isDark),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                if (tagLabels.length > 3)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: CanteenTheme.surfaceMutedBg(isDark),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '+${tagLabels.length - 3}',
                      style: TextStyle(
                        fontSize: 11,
                        color: CanteenTheme.textTertiaryColor(isDark),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (dishNames.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.thumb_up_alt_rounded,
                  size: 13,
                  color: CanteenTheme.accentStrongColor(isDark),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '推荐：${dishNames.join(' · ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: CanteenTheme.accentStrongColor(isDark),
                    ),
                  ),
                ),
              ],
            ),
          ],
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
                  '${_reviewAuthorText(nickname, review['created_at'])}${review['history_count'] is num && (review['history_count'] as num).toInt() > 1 ? ' · ${review['history_count']} 次到访' : ''}${review['credit_score'] is num && (review['credit_score'] as num).toInt() > 0 ? ' · 诚信 ${(review['credit_score'] as num).toInt()}' : ''}',
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
                      : () => onVote(
                            id,
                            source,
                            myVote == 'up' ? 'none' : 'up',
                          ),
                ),
                const SizedBox(width: 12),
                _buildVoteButton(
                  icon: Icons.thumb_down_alt_outlined,
                  iconSelected: Icons.thumb_down_alt_rounded,
                  count: unhelpfulCount,
                  selected: myVote == 'down',
                  onTap: isVoting
                      ? null
                      : () => onVote(
                            id,
                            source,
                            myVote == 'down' ? 'none' : 'down',
                          ),
                ),
              ],
              if (!isOwn && onReport != null) ...[
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value == 'report') onReport!(id, source);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'report', child: Text('举报该评价')),
                  ],
                ),
              ],
              if (isOwn && isLatestV2 && onEditLatestReview != null)
                PopupMenuButton<String>(
                  tooltip: '评价操作',
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value == 'edit') onEditLatestReview!();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text('修改这条评价'),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDimensionBadge(String label, dynamic rawScore) {
    final score = rawScore is num
        ? rawScore.toDouble()
        : double.tryParse('$rawScore') ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceMutedBg(isDark),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label ${score.toStringAsFixed(1)}',
        style: TextStyle(
          fontSize: 10,
          color: CanteenTheme.textSecondaryColor(isDark),
          fontWeight: FontWeight.w600,
        ),
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

  static const Map<String, String> _canteenTagMap = {
    'taste_good': '味道不错',
    'portion_enough': '分量足',
    'price_fair': '价格合适',
    'serving_fast': '出餐快',
    'queue_long': '排队久',
    'recommended_window': '推荐窗口',
    'clean': '卫生干净',
    'service_warm': '服务热情',
    'environment_clean': '环境整洁',
    'good_value': '性价比高',
  };

  List<String> _parseTagLabels(dynamic rawTags) {
    if (rawTags == null) return [];
    List<dynamic>? list;
    if (rawTags is List) {
      list = rawTags;
    } else if (rawTags.toString().trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawTags.toString());
        if (decoded is List) list = decoded;
      } catch (_) {}
    }
    if (list == null) return [];
    return list
        .map((tag) => _canteenTagMap[tag.toString()] ?? tag.toString())
        .where((label) => label.trim().isNotEmpty)
        .toList();
  }

  List<String> _parseRecommendedDishNames(Map<String, dynamic> review) {
    final recs = review['recommended_dishes'];
    if (recs is List) {
      return recs
          .map((item) {
            if (item is Map) {
              return item['name']?.toString() ?? '';
            }
            return item.toString();
          })
          .where((name) => name.trim().isNotEmpty)
          .toList();
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
