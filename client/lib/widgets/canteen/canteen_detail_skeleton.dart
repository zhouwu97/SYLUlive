import 'package:flutter/material.dart';

import '../../config/api_constants.dart';
import 'canteen_theme.dart';
import 'canteen_status_image.dart';

/// 商家详情首屏骨架。保持与实际布局相同的高度，避免请求返回时页面结构跳变。
/// 静态色块，不做 shimmer 循环动画。
class CanteenDetailSkeleton extends StatelessWidget {
  final String imageUrl;
  final bool offline;
  final Object? heroTag;
  final bool includeHero;

  const CanteenDetailSkeleton({
    super.key,
    this.imageUrl = '',
    this.offline = false,
    this.heroTag,
    this.includeHero = true,
  });

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

    final cover = _buildCover(isDark);
    final heroCover = heroTag == null
        ? cover
        : Hero(
            tag: heroTag!,
            child: cover,
          );

    final children = <Widget>[
      if (includeHero)
        // 独立使用骨架时保留入口封面；详情页会把 Hero 提升到稳定的页面根布局。
        ClipRRect(
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(CanteenTheme.radiusLg),
          ),
          child: SizedBox(
            height: heroHeight,
            width: double.infinity,
            child: heroCover,
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
          itemBuilder: (_, __) => block(148, 130, CanteenTheme.radiusMd),
        ),
      ),
      const SizedBox(height: 24),
    ];

    if (!includeHero) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: children,
    );
  }

  Widget _buildCover(bool isDark) {
    if (imageUrl.trim().isEmpty) return _placeholder(isDark);
    return CanteenStatusImage(
      imageUrl: ApiConstants.fullUrl(imageUrl),
      variant: 'medium',
      offline: offline,
      fit: BoxFit.cover,
      errorWidget: (_, __, ___) => _placeholder(isDark),
      placeholder: (_, __) => _placeholder(isDark),
    );
  }

  Widget _placeholder(bool isDark) {
    return Container(
      color: CanteenTheme.surfaceMutedBg(isDark),
      alignment: Alignment.center,
      child: Icon(
        Icons.restaurant_rounded,
        size: 44,
        color: CanteenTheme.textTertiaryColor(isDark),
      ),
    );
  }
}
