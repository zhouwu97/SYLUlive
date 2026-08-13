import 'package:flutter/material.dart';

import 'canteen_theme.dart';

/// 食堂详情头部信息区：图片下方直接铺在页面上，不套外层白色 InfoCard。
/// 店名 → ★评分 · 人数 → 菜品/实拍统计。
class CanteenDetailHeader extends StatelessWidget {
  final String name;
  final double rating;
  final int ratingCount;
  final int dishCount;
  final int dishPhotoCount;

  const CanteenDetailHeader({
    super.key,
    required this.name,
    required this.rating,
    required this.ratingCount,
    this.dishCount = 0,
    this.dishPhotoCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: CanteenTheme.textPrimaryColor(isDark),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.star_rounded,
                size: 16,
                color: CanteenTheme.accentColor(isDark),
              ),
              const SizedBox(width: 4),
              Text(
                rating.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '$ratingCount 人评价',
                style: TextStyle(
                  fontSize: 14,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ],
          ),
          if (dishCount > 0) ...[
            const SizedBox(height: 6),
            Text(
              '$dishCount 道菜 · $dishPhotoCount 张同学实拍',
              style: TextStyle(
                fontSize: 13,
                color: CanteenTheme.textTertiaryColor(isDark),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
