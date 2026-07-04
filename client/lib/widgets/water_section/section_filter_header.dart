import 'package:flutter/material.dart';

import '../../models/water_section.dart';
import 'section_tab_bar.dart';

/// 单行横向滑动筛选栏：推荐 / 最新 / 精华 / 关注 | 全部 / 标签 | 筛选按钮
///
/// 不再分两行展示排序和标签，所有 chip 在同一行横向滑动。
class SectionFilterHeader extends StatelessWidget {
  final List<SectionSortOption> sortOptions;
  final String currentSort;
  final WaterSection section;
  final int? selectedTagId;
  final Color accentColor;
  final bool isDark;
  final ValueChanged<String> onSortChanged;
  final ValueChanged<int?> onTagChanged;

  const SectionFilterHeader({
    super.key,
    required this.sortOptions,
    required this.currentSort,
    required this.section,
    required this.selectedTagId,
    required this.accentColor,
    required this.isDark,
    required this.onSortChanged,
    required this.onTagChanged,
  });

  static const double height = 42;

  @override
  Widget build(BuildContext context) {
    final tags = section.enabledTags;
    final items = <Widget>[];

    // 排序选项
    for (final option in sortOptions) {
      final selected = option.sort == currentSort;
      items.add(_buildChip(
        label: option.label,
        selected: selected,
        isSort: true,
        onTap: () => onSortChanged(option.sort),
      ));
    }

    // 分隔符
    if (tags.isNotEmpty) {
      items.add(_buildDivider());
    }

    // 全部 + 标签
    items.add(_buildChip(
      label: '全部',
      selected: selectedTagId == null,
      onTap: () => onTagChanged(null),
    ));
    for (final tag in tags) {
      items.add(_buildChip(
        label: tag.name,
        selected: selectedTagId == tag.id,
        onTap: () => onTagChanged(tag.id),
      ));
    }

    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, index) => items[index],
      ),
    );
  }

  Widget _buildChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool isSort = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: isSort ? 14 : 12,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: selected
              ? accentColor.withValues(alpha: isDark ? 0.20 : 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: isSort ? 14 : 12.5,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              color: selected
                  ? accentColor
                  : (isDark ? Colors.white54 : const Color(0xFF667085)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Center(
      child: Container(
        width: 1,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        color: isDark
            ? Colors.white.withValues(alpha: 0.12)
            : const Color(0xFFE5E7EB),
      ),
    );
  }
}
