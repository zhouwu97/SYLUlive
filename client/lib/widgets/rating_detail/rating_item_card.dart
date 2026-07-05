import 'package:flutter/material.dart';
import 'ranking_tokens.dart';

class RatingItemCard extends StatelessWidget {
  final String userName;
  final String comment;
  final int star;
  final bool isOwn;
  final VoidCallback? onLongPress;

  const RatingItemCard({
    super.key,
    required this.userName,
    required this.comment,
    required this.star,
    this.isOwn = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final item = InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
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
                  child: Text(
                    userName,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: RankingTokens.titleColor(isDark),
                    ),
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
            if (comment.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 36),
                child: Text(
                  comment.trim(),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: RankingTokens.subColor(isDark),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Column(
      children: [
        item,
        Divider(
          height: 1,
          thickness: 1,
          indent: 44,
          color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.04),
        ),
      ],
    );
  }
}
