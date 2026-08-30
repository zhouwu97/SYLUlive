import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_spacing.dart';

/// 版块 Feed 的排序栏。
class SectionFilterHeader extends StatelessWidget {
  final String currentFilterKey;
  final Color accentColor;
  final bool isDark;
  final ValueChanged<String> onFilterChanged;

  const SectionFilterHeader({
    super.key,
    required this.currentFilterKey,
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
