import 'package:flutter/material.dart';

import '../../models/canteen_ranking.dart';
import 'canteen_theme.dart';

/// 排行页排序筛选条：综合 / 评分 / 评价人数。
/// 热度待热度表上线后再开放，不在无真实数据时提供假的热度排序。
class CanteenRankingFilterBar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  const CanteenRankingFilterBar({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _chip(isDark, '综合排序', CanteenRankingSort.composite),
          const SizedBox(width: 8),
          _chip(isDark, '评分优先', CanteenRankingSort.rating),
          const SizedBox(width: 8),
          _chip(isDark, '评价人数', CanteenRankingSort.reviewCount),
        ],
      ),
    );
  }

  Widget _chip(bool isDark, String label, String value) {
    final isSel = selected == value;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSel
              ? CanteenTheme.accentSoftColor(isDark)
              : CanteenTheme.surfaceBg(isDark),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color:
                isSel ? CanteenTheme.accentColor(isDark) : CanteenTheme.borderColor(isDark),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSel ? FontWeight.w800 : FontWeight.w600,
            color: isSel
                ? CanteenTheme.accentStrongColor(isDark)
                : CanteenTheme.textSecondaryColor(isDark),
          ),
        ),
      ),
    );
  }
}
