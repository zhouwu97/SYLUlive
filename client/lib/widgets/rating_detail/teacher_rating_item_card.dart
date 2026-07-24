import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import '../../utils/rating_time_formatter.dart';
import '../cached_avatar.dart';
import 'ranking_tokens.dart';
import 'rating_action_row.dart';
import 'rating_star_row.dart';

class TeacherRatingItemCard extends StatelessWidget {
  final String userName;
  final String? userAvatar;
  final String comment;
  final int star;
  final bool isOwn;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int helpfulCount;
  final int unhelpfulCount;
  final String? myVote;
  final Color accent;
  final VoidCallback? onHelpful;
  final VoidCallback? onUnhelpful;
  final VoidCallback? onReport;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const TeacherRatingItemCard({
    super.key,
    required this.userName,
    required this.comment,
    required this.star,
    required this.accent,
    this.userAvatar,
    this.isOwn = false,
    this.createdAt,
    this.updatedAt,
    this.helpfulCount = 0,
    this.unhelpfulCount = 0,
    this.myVote,
    this.onHelpful,
    this.onUnhelpful,
    this.onReport,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avatarFill = isDark
        ? accent.withValues(alpha: 0.20)
        : accent.withValues(alpha: 0.12);

    return Container(
      decoration: RankingTokens.cardDecoration(
        isDark,
        borderOverride: accent.withValues(alpha: isDark ? 0.26 : 0.18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: accent.withValues(alpha: isDark ? 0.48 : 0.30),
                    ),
                  ),
                  child: CachedAvatar(
                    radius: 17,
                    imageUrl: userAvatar?.trim().isNotEmpty == true
                        ? ApiConstants.fullUrl(userAvatar!.trim())
                        : null,
                    fallbackIcon: Icons.person_rounded,
                    fallbackBackgroundColor: avatarFill,
                    fallbackIconColor: accent,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        userName.isEmpty ? '匿名同学' : userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: RankingTokens.titleColor(isDark),
                        ),
                      ),
                      if (createdAt != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          formatRatingTime(createdAt, updatedAt),
                          style: TextStyle(
                            fontSize: 11,
                            color: RankingTokens.mutedColor(isDark),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                RatingStarRow(value: star.toDouble(), size: 16),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              comment.trim().isEmpty ? '仅评分，未填写文字评价。' : comment.trim(),
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                fontStyle: comment.trim().isEmpty
                    ? FontStyle.italic
                    : FontStyle.normal,
                color: comment.trim().isEmpty
                    ? RankingTokens.mutedColor(isDark)
                    : RankingTokens.subColor(isDark),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 3),
              child: Divider(
                height: 1,
                color: RankingTokens.borderColor(isDark),
              ),
            ),
            RatingActionRow(
              isOwn: isOwn,
              helpfulCount: helpfulCount,
              unhelpfulCount: unhelpfulCount,
              myVote: myVote,
              onHelpful: onHelpful,
              onUnhelpful: onUnhelpful,
              onReport: onReport,
              onEdit: onEdit,
              onDelete: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}
