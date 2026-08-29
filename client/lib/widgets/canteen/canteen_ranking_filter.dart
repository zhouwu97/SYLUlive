import 'package:flutter/material.dart';

import '../../models/canteen_ranking.dart';
import 'canteen_theme.dart';

/// 排行页位置筛选可选值：'' 表示全部。
const List<String> kCanteenLocationFilterOptions = [
  '',
  '一食堂',
  '二食堂',
  '一楼',
  '二楼',
];

String canteenLocationFilterLabel(String value) {
  return value.isEmpty ? '位置' : value;
}

/// 排行页排序筛选条：综合 / 评分 / 评价人数 + 位置筛选小按钮。
/// 热度待热度表上线后再开放，不在无真实数据时提供假的热度排序。
class CanteenRankingFilterBar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;
  final String locationFilter;
  final ValueChanged<String> onLocationFilterChanged;

  const CanteenRankingFilterBar({
    super.key,
    required this.selected,
    required this.onChanged,
    this.locationFilter = '',
    required this.onLocationFilterChanged,
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
          const SizedBox(width: 8),
          _locationChip(context, isDark),
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

  Widget _locationChip(BuildContext context, bool isDark) {
    final isSel = locationFilter.isNotEmpty;
    return GestureDetector(
      onTap: () => _showLocationSheet(context, isDark),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSel
              ? CanteenTheme.accentSoftColor(isDark)
              : CanteenTheme.surfaceBg(isDark),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isSel
                ? CanteenTheme.accentColor(isDark)
                : CanteenTheme.borderColor(isDark),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_list_rounded,
              size: 15,
              color: isSel
                  ? CanteenTheme.accentStrongColor(isDark)
                  : CanteenTheme.textSecondaryColor(isDark),
            ),
            const SizedBox(width: 4),
            Text(
              canteenLocationFilterLabel(locationFilter),
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSel ? FontWeight.w800 : FontWeight.w600,
                color: isSel
                    ? CanteenTheme.accentStrongColor(isDark)
                    : CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLocationSheet(BuildContext context, bool isDark) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          decoration: BoxDecoration(
            color: CanteenTheme.surfaceBg(isDark),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '按位置筛选',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: CanteenTheme.textPrimaryColor(isDark),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '只看指定食堂或楼层的商家',
                  style: TextStyle(
                    fontSize: 12,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
                const SizedBox(height: 14),
                for (final option in kCanteenLocationFilterOptions)
                  _locationOptionTile(sheetContext, isDark, option),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _locationOptionTile(
      BuildContext sheetContext, bool isDark, String option) {
    final isSel = locationFilter == option;
    final label = option.isEmpty ? '全部商家' : option;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        onLocationFilterChanged(option);
        Navigator.pop(sheetContext);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: isSel ? FontWeight.w800 : FontWeight.w600,
                  color: isSel
                      ? CanteenTheme.accentStrongColor(isDark)
                      : CanteenTheme.textPrimaryColor(isDark),
                ),
              ),
            ),
            if (isSel)
              Icon(Icons.check_rounded,
                  size: 18, color: CanteenTheme.accentStrongColor(isDark)),
          ],
        ),
      ),
    );
  }
}
