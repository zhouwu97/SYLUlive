import 'package:flutter/material.dart';
import 'ranking_tokens.dart';
import '../../utils/rating_time_formatter.dart';
import 'rating_action_row.dart';

class RatingItemCard extends StatelessWidget {
  final String userName;
  final String comment;
  final int star;
  final bool isOwn;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int helpfulCount;
  final int unhelpfulCount;
  final String? myVote;
  final VoidCallback? onHelpful;
  final VoidCallback? onUnhelpful;
  final VoidCallback? onReport;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const RatingItemCard({
    super.key,
    required this.userName,
    required this.comment,
    required this.star,
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

    return Container(
      decoration: RankingTokens.cardDecoration(isDark),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor:
                      isDark ? Colors.white12 : Colors.grey.shade200,
                  child: Text(
                    userName.isNotEmpty ? userName[0] : '?',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        userName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: RankingTokens.titleColor(isDark),
                          height: 1.2,
                        ),
                      ),
                      if (createdAt != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          formatRatingTime(createdAt, updatedAt),
                          style: TextStyle(
                            fontSize: 10,
                            color: RankingTokens.mutedColor(isDark),
                            height: 1.1,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Text(
                  '★' * star + '☆' * (5 - star),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.amber,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: comment.trim().isNotEmpty
                  ? Text(
                      comment.trim(),
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: RankingTokens.subColor(isDark),
                      ),
                    )
                  : Text(
                      '仅评分，未填写文字评价',
                      style: TextStyle(
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                        color: RankingTokens.mutedColor(isDark),
                      ),
                    ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: RatingActionRow(
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
            ),
          ],
        ),
      ),
    );
  }
}
