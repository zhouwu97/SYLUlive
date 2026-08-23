import 'package:flutter/material.dart';

import '../../models/topic.dart';
import '../../models/water_section.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_spacing.dart';

/// 版块 Feed 的排序栏。排序与话题是两种不同的状态，不再混成一排胶囊。
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

  static const double height = 50;

  @override
  Widget build(BuildContext context) {
    const tabs = [
      ('推荐', 'mode:recommend'),
      ('最新', 'mode:latest'),
      ('精华', 'mode:featured'),
    ];
    final inactive =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

    return Container(
      height: height,
      color:
          isDark ? AppColors.surfacePrimaryDark : AppColors.surfacePrimaryLight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        children: tabs.map((tab) {
          final selected = currentFilterKey == tab.$2;
          return Expanded(
            child: Semantics(
              selected: selected,
              button: true,
              label: '排序 ${tab.$1}',
              child: InkWell(
                onTap: () => onFilterChanged(tab.$2),
                child: SizedBox(
                  height: height,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: AppMotion.micro,
                            curve: AppMotion.standard,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight:
                                  selected ? FontWeight.w700 : FontWeight.w500,
                              color: selected ? accentColor : inactive,
                            ),
                            child: Text(tab.$1),
                          ),
                        ),
                      ),
                      AnimatedContainer(
                        duration: AppMotion.micro,
                        curve: AppMotion.standard,
                        height: 3,
                        width: selected ? 28 : 0,
                        decoration: BoxDecoration(
                          color: accentColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(growable: false),
      ),
    );
  }
}

/// 版块热门话题。话题来自 Topic 系统，不读取 WaterSectionTag。
class SectionTopicRow extends StatelessWidget {
  final List<Topic> topics;
  final int? selectedTopicId;
  final Color accentColor;
  final bool isDark;
  final ValueChanged<Topic> onTopicSelected;

  const SectionTopicRow({
    super.key,
    required this.topics,
    required this.selectedTopicId,
    required this.accentColor,
    required this.isDark,
    required this.onTopicSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (topics.isEmpty) return const SizedBox.shrink();
    final muted =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '热门话题',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: muted,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: topics.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.xs),
              itemBuilder: (context, index) {
                final topic = topics[index];
                final selected = topic.id == selectedTopicId;
                return Semantics(
                  button: true,
                  selected: selected,
                  label: '筛选话题 ${topic.name}',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onTopicSelected(topic),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Center(
                        child: Text(
                          '#${topic.name}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected ? accentColor : muted,
                            decoration: selected
                                ? TextDecoration.underline
                                : TextDecoration.none,
                            decorationColor: accentColor,
                            decorationThickness: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
