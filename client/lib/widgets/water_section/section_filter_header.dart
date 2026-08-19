import 'package:flutter/material.dart';

import '../../models/water_section.dart';
import '../../theme/app_colors.dart';

/// 分类页顶部单行标签栏（推荐/最新/精华 + 细分标签）
class SectionFilterHeader extends StatelessWidget {
  final String currentFilterKey;
  final WaterSection section;
  final Color accentColor;
  final bool isDark;
  final ValueChanged<String> onFilterChanged;

  const SectionFilterHeader({
    super.key,
    required this.currentFilterKey,
    required this.section,
    required this.accentColor,
    required this.isDark,
    required this.onFilterChanged,
  });

  static const double height = 44;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];

    // 前三个固定标签
    items.add(
        _buildTextTab(label: '推荐', filterKey: 'mode:recommend', isFixed: true));
    items.add(const SizedBox(width: 10));
    items.add(
        _buildTextTab(label: '最新', filterKey: 'mode:latest', isFixed: true));
    items.add(const SizedBox(width: 10));
    items.add(
        _buildTextTab(label: '精华', filterKey: 'mode:featured', isFixed: true));

    // 版块自定义标签
    if (section.enabledTags.isNotEmpty) {
      for (int i = 0; i < section.enabledTags.length; i++) {
        final tag = section.enabledTags[i];
        items.add(_buildTextTab(
            label: tag.name, filterKey: 'tag:${tag.id}', isFixed: false));
        if (i < section.enabledTags.length - 1) {
          items.add(const SizedBox(width: 10));
        }
      }
    }

    return SizedBox(
      height: height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: items,
      ),
    );
  }

  Widget _buildTextTab({
    required String label,
    required String filterKey,
    required bool isFixed,
  }) {
    final selected = filterKey == currentFilterKey;

    return GestureDetector(
      onTap: () => onFilterChanged(filterKey),
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.1)
                : (isDark
                    ? AppColors.surfaceMutedDark
                    : AppColors.surfaceMutedLight),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.2)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: selected
                  ? accentColor
                  : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
            ),
          ),
        ),
      ),
    );
  }
}
