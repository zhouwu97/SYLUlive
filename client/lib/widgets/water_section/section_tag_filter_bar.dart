import 'package:flutter/material.dart';

import '../../models/water_section.dart';
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
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            right: 50,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              itemCount: tags.length + 1, // +1 for "全部"
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _buildChip(
                    label: '全部',
                    selected: selectedTagId == null,
                    onTap: () => onTagChanged(null),
                  );
                }
                final tag = tags[index - 1];
                return _buildChip(
                  label: tag.name,
                  selected: selectedTagId == tag.id,
                  onTap: () => onTagChanged(tag.id),
                );
              },
            ),
          ),
          // 右侧排序按钮
          Positioned(
            top: 4,
            right: 12,
            child: _buildSortMenuButton(context),
          ),
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
                  : const Color(0xFFF4F6F8)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? accentColor
                : (isDark ? Colors.white54 : const Color(0xFF667085)),
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
      color: isDark ? const Color(0xFF171B24) : Colors.white,
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
