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

    String sampleHint;
    if (ratingCount <= 2) {
      sampleHint = '样本较少';
    } else if (ratingCount <= 10) {
      sampleHint = '$ratingCount 条样本';
    } else {
      sampleHint = '评价数据逐渐稳定';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: RankingTokens.cardDecoration(isDark),
      child: Column(
        children: [
          Row(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    averageStar.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w900,
                      height: 1.0,
                      color: RankingTokens.titleColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '★★★★★',
                    style: TextStyle(
                      fontSize: 13,
                      color: accent,
                      letterSpacing: 2.0,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '基于 $ratingCount 条评价',
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
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withValues(alpha: 0.04) : RankingTokens.pageBg(isDark),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 14,
                  color: RankingTokens.subColor(isDark),
                ),
                const SizedBox(width: 6),
                Text(
                  sampleHint,
                  style: TextStyle(
                    fontSize: 11,
                    color: RankingTokens.subColor(isDark),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
