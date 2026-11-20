import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../utils/canteen_review_date.dart';
import 'canteen_theme.dart';
import 'dish_review_report.dart';

/// 菜品页的一条同学评价：头像、昵称与时间、菜品三维分胶囊、评价正文。
///
/// 菜品详情的预览和“全部评价”页共用，保证两处样式一致；外层卡片由调用方决定。
class DishReviewTile extends StatelessWidget {
  final Map<String, dynamic> review;

  /// 非本人评价才显示举报入口。
  final bool canReport;

  /// 预览里正文最多两行；全部评价页完整展示。
  final int? maxCommentLines;

  const DishReviewTile({
    super.key,
    required this.review,
    required this.canReport,
    this.maxCommentLines,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final name = review['user_name']?.toString().trim() ?? '';
    final comment = review['comment']?.toString().trim() ?? '';
    final createdAt = DateTime.tryParse(review['created_at']?.toString() ?? '');
    final updatedAt = DateTime.tryParse(review['updated_at']?.toString() ?? '');
    final dateText = formatCanteenReviewDate(createdAt, updatedAt);
    final scores = dishReviewScores(review);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Avatar(
          name: name,
          avatar: review['user_avatar']?.toString().trim() ?? '',
          isDark: isDark,
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
                      name.isEmpty ? '匿名同学' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: CanteenTheme.textPrimaryColor(isDark),
                      ),
                    ),
                  ),
                  if (dateText.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        dateText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: CanteenTheme.textTertiaryColor(isDark),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (scores != null) ...[
                const SizedBox(height: 6),
                Semantics(
                  label: dishReviewScoreLine(review),
                  excludeSemantics: true,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _ScorePill(
                          label: '味道', score: scores.taste, isDark: isDark),
                      _ScorePill(
                          label: '性价比', score: scores.value, isDark: isDark),
                      _ScorePill(
                          label: '分量', score: scores.portion, isDark: isDark),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                comment.isEmpty ? '这位同学没有留下文字评价' : comment,
                maxLines: maxCommentLines,
                overflow: maxCommentLines == null
                    ? TextOverflow.visible
                    : TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: comment.isEmpty
                      ? CanteenTheme.textTertiaryColor(isDark)
                      : CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ],
          ),
        ),
        if (canReport)
          SizedBox(
            width: 32,
            height: 32,
            child: PopupMenuButton<String>(
              tooltip: '举报评价',
              padding: EdgeInsets.zero,
              icon: Icon(
                Icons.more_horiz_rounded,
                size: 18,
                color: CanteenTheme.textTertiaryColor(isDark),
              ),
              onSelected: (_) => reportDishReview(context, review),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'report', child: Text('举报该评价')),
              ],
            ),
          ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  final String name;
  final String avatar;
  final bool isDark;

  const _Avatar(
      {required this.name, required this.avatar, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final initial = Text(
      name.isEmpty ? '同' : String.fromCharCode(name.runes.first),
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: CanteenTheme.accentStrongColor(isDark),
      ),
    );
    return ExcludeSemantics(
      child: Container(
        width: 32,
        height: 32,
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: CanteenTheme.accentSoftColor(isDark),
        ),
        child: avatar.isEmpty
            ? initial
            : CachedNetworkImage(
                imageUrl: ApiConstants.fullUrl(avatar),
                width: 32,
                height: 32,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Center(child: initial),
              ),
      ),
    );
  }
}

class _ScorePill extends StatelessWidget {
  final String label;
  final int score;
  final bool isDark;

  const _ScorePill(
      {required this.label, required this.score, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: CanteenTheme.accentSoftColor(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
      ),
      child: Text(
        '$label $score',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: CanteenTheme.accentStrongColor(isDark),
        ),
      ),
    );
  }
}
