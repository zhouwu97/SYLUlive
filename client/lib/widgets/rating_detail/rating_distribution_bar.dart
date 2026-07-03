import 'package:flutter/material.dart';

class RatingDistributionBar extends StatelessWidget {
  final int star;
  final double percentage;

  const RatingDistributionBar({
    super.key,
    required this.star,
    required this.percentage,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Container(
      height: 14,
      alignment: Alignment.center,
      child: Row(
        children: [
          // Star text representation (★★★★★)
        Text(
          '★' * star + '☆' * (5 - star),
          style: TextStyle(
            fontSize: 12,
            height: 1.0,
            color: isDark ? Colors.grey.shade400 : Colors.grey.shade500,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(width: 8),
        // Progress bar
        Expanded(
          child: Stack(
            children: [
              Container(
                height: 5,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              FractionallySizedBox(
                widthFactor: percentage,
                child: Container(
                  height: 5,
                  decoration: BoxDecoration(
                    color: primaryColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Percentage text
        SizedBox(
          width: 40,
          child: Text(
            '${(percentage * 100).toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')}%',
            style: TextStyle(
              fontSize: 11,
              color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
      ),
    );
  }
}
