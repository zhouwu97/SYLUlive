import 'package:flutter/material.dart';

import '../../models/water_section.dart';
import '../../theme/app_colors.dart';
import 'section_tab_bar.dart';

/// 版块标签筛选栏（全部 / tag1 / tag2 / ... + 筛选按钮）。
class SectionTagFilterBar extends StatelessWidget {
  final WaterSection section;
  final int? selectedTagId;
  final String currentSort;
  final Color accentColor;
  final bool isDark;
  final ValueChanged<int?> onTagChanged;
  final ValueChanged<String> onSortChanged;

  const SectionTagFilterBar({
    super.key,
    required this.section,
    required this.selectedTagId,
    required this.currentSort,
    required this.accentColor,
    required this.isDark,
    required this.onTagChanged,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    final tags = section.enabledTags;
    if (tags.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              itemCount: tags.length + 1,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                if (index == 0) {
                  final isAll = selectedTagId == null;
                  return _buildChip(
                    label: '全部',
                    selected: isAll,
                    onTap: () => onTagChanged(null),
                  );
                }
                final tag = tags[index - 1];
                final isSelected = selectedTagId == tag.id;
                return _buildChip(
                  label: tag.name,
                  selected: isSelected,
                  onTap: () => onTagChanged(tag.id),
                );
              },
            ),
          ),
          _buildSortMenuButton(context),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? accentColor.withValues(alpha: isDark ? 0.20 : 0.12)
              : (isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : AppColors.surfaceMutedLight),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? accentColor
                : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
          ),
        ),
      ),
    );
  }

  Widget _buildSortMenuButton(BuildContext context) {
    final isDefaultSort = currentSort == 'all';
    return PopupMenuButton<String>(
      tooltip: '排序方式',
      position: PopupMenuPosition.under,
      offset: const Offset(0, 4),
      color: isDark ? AppColors.surfaceSecondaryDark : AppColors.surfaceSecondaryLight,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      itemBuilder: (context) => kSectionSortOptions
          .map((o) => PopupMenuItem<String>(
                value: o.sort,
                child: Row(
                  children: [
                    Icon(
                      currentSort == o.sort
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 15,
                      color: currentSort == o.sort ? accentColor : null,
                    ),
                    const SizedBox(width: 8),
                    Text(o.label),
                  ],
                ),
              ))
          .toList(),
      onSelected: onSortChanged,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: accentColor.withValues(alpha: isDark ? 0.14 : 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Stack(
          children: [
            Center(
              child: Icon(Icons.tune_rounded, size: 16, color: accentColor),
            ),
            if (!isDefaultSort)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: accentColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
