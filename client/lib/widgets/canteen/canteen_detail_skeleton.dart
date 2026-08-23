import 'package:flutter/material.dart';

import 'canteen_theme.dart';

/// 商家详情首屏骨架。保持与实际布局相同的高度，避免请求返回时页面结构跳变。
/// 静态色块，不做 shimmer 循环动画。
class CanteenDetailSkeleton extends StatelessWidget {
  const CanteenDetailSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = CanteenTheme.surfaceMutedBg(isDark);

    final heroHeight =
        (MediaQuery.of(context).size.width * 0.5).clamp(190.0, 230.0);

    Widget block(double width, double height, double radius) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: muted,
          borderRadius: BorderRadius.circular(radius),
        ),
      );
    }

    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: [
        // Hero 占位
        ClipRRect(
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(CanteenTheme.radiusLg),
          ),
          child: SizedBox(
            height: heroHeight,
            width: double.infinity,
            child: ColoredBox(color: muted),
          ),
        ),
        // 店名 / 评分 / 统计
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              block(180, 22, CanteenTheme.radiusSm),
              const SizedBox(height: 12),
              block(140, 14, CanteenTheme.radiusSm),
              const SizedBox(height: 9),
              block(110, 13, CanteenTheme.radiusSm),
            ],
          ),
        ),
        const SizedBox(height: 28),
        // “商家菜品”标题 + 图鉴横排
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: block(96, 17, CanteenTheme.radiusSm),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 130,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 3,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, __) =>
                block(148, 130, CanteenTheme.radiusMd),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
