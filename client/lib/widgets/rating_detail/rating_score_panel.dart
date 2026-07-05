import 'package:flutter/material.dart';
import 'ranking_tokens.dart';
import 'rating_distribution_bar.dart';

class RatingScorePanel extends StatelessWidget {
  final double averageStar;
  final int ratingCount;
  final List<int> starCounts;
  final Color? accentOverride;

  const RatingScorePanel({
    super.key,
    required this.averageStar,
    required this.ratingCount,
    required this.starCounts,
    this.accentOverride,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = accentOverride ?? RankingTokens.teacherAccent(isDark);

    final counts = starCounts.length == 5 ? starCounts : [0, 0, 0, 0, 0];
    final total = counts.fold<int>(0, (prev, element) => prev + element);
    final reversedCounts = counts.reversed.toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: RankingTokens.cardDecoration(isDark),
      child: Row(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '评分',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: RankingTokens.subColor(isDark),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                averageStar.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                  color: RankingTokens.titleColor(isDark),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$ratingCount人评价',
                style: TextStyle(
                  fontSize: 11,
                  color: RankingTokens.subColor(isDark),
                ),
              ),
            ],
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(5, (index) {
                final starValue = 5 - index;
                final count = reversedCounts[index];
                final percentage = total == 0 ? 0.0 : count / total;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: RatingDistributionBar(
                    star: starValue,
                    percentage: percentage,
                    accentOverride: accent,
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
