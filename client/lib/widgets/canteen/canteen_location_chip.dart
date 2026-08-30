import 'package:flutter/material.dart';

import 'canteen_theme.dart';

/// 食堂位置系统标签（一食堂/二食堂 · 一楼/二楼）。
/// 与排行条目"样本提示"同款小胶囊样式；label 为空时不占位。
class CanteenLocationChip extends StatelessWidget {
  final String label;

  const CanteenLocationChip({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceMutedBg(isDark),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: CanteenTheme.textSecondaryColor(isDark),
        ),
      ),
    );
  }
}
