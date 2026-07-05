import 'package:flutter/material.dart';
import 'ranking_tokens.dart';

class MyRatingCard extends StatelessWidget {
  final int currentStar;
  final String? currentComment;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool isDeleting;
  final Color? accentOverride;

  const MyRatingCard({
    super.key,
    required this.currentStar,
    required this.currentComment,
    required this.onEdit,
    required this.onDelete,
    this.isDeleting = false,
    this.accentOverride,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = accentOverride ?? RankingTokens.teacherAccent(isDark);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: RankingTokens.cardBg(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: accent.withValues(alpha: isDark ? 0.18 : 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '我的评价',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: RankingTokens.titleColor(isDark),
                ),
              ),
              const Spacer(),
              if (isDeleting)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_horiz,
                    color: RankingTokens.subColor(isDark),
                    size: 18,
                  ),
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value == 'edit') onEdit();
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('修改评价')),
                    PopupMenuItem(value: 'delete', child: Text('删除评价')),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor:
                    isDark ? accent.withValues(alpha: 0.18) : accent.withValues(alpha: 0.08),
                child: Text(
                  '我',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '我',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: RankingTokens.titleColor(isDark),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '★' * currentStar + '☆' * (5 - currentStar),
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.amber,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${currentStar.toDouble()}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: RankingTokens.titleColor(isDark),
                ),
              ),
            ],
          ),
          if (currentComment != null && currentComment!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              currentComment!.trim(),
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: RankingTokens.subColor(isDark),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
