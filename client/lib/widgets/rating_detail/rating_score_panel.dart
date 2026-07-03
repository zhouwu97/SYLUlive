import 'package:flutter/material.dart';
import 'rating_distribution_bar.dart';

class RatingScorePanel extends StatelessWidget {
  final double averageStar;
  final int ratingCount;
  final List<int> starCounts; // Ensure this is [count1, count2, count3, count4, count5]

  const RatingScorePanel({
    super.key,
    required this.averageStar,
    required this.ratingCount,
    required this.starCounts,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Ensure we have exactly 5 elements
    final counts = starCounts.length == 5 ? starCounts : [0, 0, 0, 0, 0];
    final total = counts.fold<int>(0, (prev, element) => prev + element);
    
    // Reverse it to map 5 stars to 1 star visually from top to bottom
    final reversedCounts = counts.reversed.toList();

    return Container(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.02),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Left side: average score and count
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '评分',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                averageStar.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  height: 1.0,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '$ratingCount人评价',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey.shade500 : Colors.grey.shade500,
                ),
              ),
            ],
          ),
          const SizedBox(width: 32),
          // Right side: star distribution
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(5, (index) {
                final starValue = 5 - index;
                final count = reversedCounts[index];
                final percentage = total == 0 ? 0.0 : count / total;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: RatingDistributionBar(
                    star: starValue,
                    percentage: percentage,
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
