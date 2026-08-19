import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// 版块主 Tab 栏（推荐/最新/精华/关注）。
/// 纯展示组件，通过回调通知外层切换 sort。
class SectionTabBar extends StatelessWidget {
  final List<SectionSortOption> options;
  final String currentSort;
  final Color accentColor;
  final bool isDark;
  final ValueChanged<String> onSortChanged;

  const SectionTabBar({
    super.key,
    required this.options,
    required this.currentSort,
    required this.accentColor,
    required this.isDark,
    required this.onSortChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          final option = options[index];
          final selected = option.sort == currentSort;
          return _buildTab(option, selected);
        },
      ),
    );
  }

  Widget _buildTab(SectionSortOption option, bool selected) {
    return GestureDetector(
      onTap: () => onSortChanged(option.sort),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? accentColor.withValues(alpha: isDark ? 0.20 : 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          option.label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: selected
                ? accentColor
                : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

class SectionSortOption {
  final String label;
  final String sort;

  const SectionSortOption({required this.label, required this.sort});
}

const kSectionSortOptions = [
  SectionSortOption(label: '推荐', sort: 'all'),
  SectionSortOption(label: '最新', sort: 'time'),
  SectionSortOption(label: '精华', sort: 'featured'),
  SectionSortOption(label: '关注', sort: 'following'),
];

/// 版块页专用排序选项（不含"关注"）
const kSectionFeedSortOptions = [
  SectionSortOption(label: '推荐', sort: 'all'),
  SectionSortOption(label: '最新', sort: 'time'),
  SectionSortOption(label: '精华', sort: 'featured'),
];
