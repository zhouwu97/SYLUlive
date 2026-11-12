import 'package:flutter/material.dart';

import '../../models/canteen_home.dart';
import '../app_card.dart';
import 'canteen_status_image.dart';
import 'canteen_theme.dart';

/// 热门菜品卡：实拍封面 + 菜名 + 所属商家 + 评分与人数。
///
/// 首页“热门菜品”和“全部热门菜品”页共用，保证两处看起来是同一种东西。
/// 近 30 天有人提到时在封面角落标出，说明它为什么“热门”。
class CanteenHotDishCard extends StatelessWidget {
  final CanteenHotDish dish;
  final VoidCallback onTap;

  const CanteenHotDishCard(
      {super.key, required this.dish, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scoreText =
        dish.averageScore > 0 ? dish.averageScore.toStringAsFixed(1) : '暂无评分';
    return Semantics(
      button: true,
      label: '${dish.name}，${dish.canteenName}，'
          '${dish.averageScore > 0 ? '$scoreText 分' : scoreText}',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AppCardSurface(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: CanteenTheme.surfaceBg(isDark),
            borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
            border: Border.all(color: CanteenTheme.borderColor(isDark)),
          ),
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CanteenStatusImage(
                        imageUrl: dish.coverImage,
                        variant: 'thumb',
                        offline: dish.isCanteenOffline,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => Container(
                          color: CanteenTheme.surfaceMutedBg(isDark),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.ramen_dining_rounded,
                            color: CanteenTheme.textTertiaryColor(isDark),
                          ),
                        ),
                      ),
                      if (dish.recentMentionCount > 0)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '近 30 天 ${dish.recentMentionCount} 人提到',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dish.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: CanteenTheme.textPrimaryColor(isDark),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        dish.canteenName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: CanteenTheme.textTertiaryColor(isDark),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.star_rounded,
                              size: 14,
                              color: CanteenTheme.accentColor(isDark)),
                          const SizedBox(width: 2),
                          Text(
                            scoreText,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: CanteenTheme.textPrimaryColor(isDark),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${dish.reviewerCount}人评',
                            style: TextStyle(
                              fontSize: 10,
                              color: CanteenTheme.textTertiaryColor(isDark),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
