import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import 'rating_star_row.dart';

class RatingSummaryCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final double averageStar;
  final int ratingCount;
  final Color? backgroundColor;

  const RatingSummaryCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.averageStar,
    required this.ratingCount,
    this.backgroundColor,
  });

  String _initial(String text) {
    final value = text.trim();
    return value.isEmpty ? '?' : value[0];
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surfaceColor =
        backgroundColor ?? (isDark ? const Color(0xFF1C2230) : Colors.white);
    final mutedTextColor = isDark ? Colors.grey.shade300 : Colors.grey.shade600;

    return Card(
      elevation: 0,
      color: surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: AppColors.brandPrimary,
              child: Text(
                _initial(title),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      height: 1.2,
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: mutedTextColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      RatingStarRow(value: averageStar, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        '$ratingCount人评价',
                        style: TextStyle(
                          fontSize: 13,
                          color: mutedTextColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              children: [
                Text(
                  averageStar.toStringAsFixed(1),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '综合评分',
                  style: TextStyle(
                    fontSize: 11,
                    color: mutedTextColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
