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
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: isDark
            ? accent.withValues(alpha: 0.1)
            : accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '我的评价',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
              const Spacer(),
              if (isDeleting)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                PopupMenuButton<String>(
                  child: Padding(
                    padding: const EdgeInsets.only(
                        left: 8, right: 0, top: 4, bottom: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '编辑',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: accent,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 14,
                          color: accent,
                        ),
                      ],
                    ),
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
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: isDark
                    ? accent.withValues(alpha: 0.18)
                    : accent.withValues(alpha: 0.1),
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
                  fontSize: 12,
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
