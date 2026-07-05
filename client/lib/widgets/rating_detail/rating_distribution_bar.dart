import 'package:flutter/material.dart';
import 'ranking_tokens.dart';

class RatingDistributionBar extends StatelessWidget {
  final int star;
  final double percentage;
  final Color? accentOverride;

  const RatingDistributionBar({
    super.key,
    required this.star,
    required this.percentage,
    this.accentOverride,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = accentOverride ?? RankingTokens.teacherAccent(isDark);

    return SizedBox(
      height: 12,
      child: Row(
        children: [
          Text(
            '★' * star + '☆' * (5 - star),
            style: TextStyle(
              fontSize: 11,
              height: 1.0,
              color: RankingTokens.subColor(isDark),
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white10
                        : Colors.black.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: percentage,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 36,
            child: Text(
              '${(percentage * 100).toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')}%',
              style: TextStyle(
                fontSize: 10,
                color: RankingTokens.subColor(isDark),
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
