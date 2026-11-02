import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text_styles.dart';

/// 液态底栏与毛玻璃共用的预设行，放在对应的 RadioGroup 内。
class SettingsEffectOption<T> extends StatelessWidget {
  const SettingsEffectOption({
    super.key,
    required this.value,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final T value;
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: '$title，$description',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
            child: Row(children: [
              Radio<T>(value: value, enabled: enabled),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(title,
                    style: AppTextStyles.bodyMedium.copyWith(
                      fontWeight: FontWeight.w600,
                      color: (dark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimaryLight)
                          .withValues(alpha: enabled ? 1 : .5),
                    )),
              ),
              Flexible(
                flex: 2,
                child: Text(description,
                    textAlign: TextAlign.end,
                    style: AppTextStyles.labelMedium.copyWith(
                      color: (dark
                              ? AppColors.textSecondaryDark
                              : AppColors.textSecondaryLight)
                          .withValues(alpha: enabled ? 1 : .5),
                    )),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
