import 'package:flutter/material.dart';

import '../../../models/water_section.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_radius.dart';
import '../../../theme/app_spacing.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/water_section/section_avatar.dart';

/// Composer 顶部的一级版块选择器。
///
/// 普通 WaterSectionTag 不在这里展示；版块只表达“发布到哪里”，
/// 话题由 PublishTopicSection 表达“正在说什么”。
class PublishSectionSelector extends StatelessWidget {
  final WaterSection section;
  final VoidCallback onTap;

  const PublishSectionSelector({
    super.key,
    required this.section,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = section.colorHex.isNotEmpty
        ? colorHexToColor(section.colorHex, fallback: AppColors.brandPrimary)
        : AppColors.brandPrimary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        0,
      ),
      child: Semantics(
        button: true,
        label: '发布到${section.title}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '发布到',
              style: AppTextStyles.titleMedium.copyWith(
                fontSize: 16,
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimaryLight,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Container(
                constraints: const BoxConstraints(minHeight: 52),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppColors.brandSurfaceDark
                      : AppColors.brandSurfaceLight,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: isDark
                        ? AppColors.borderNormalDark
                        : AppColors.borderSubtleLight,
                  ),
                ),
                child: Row(
                  children: [
                    SectionAvatar(
                      section: section,
                      size: 28,
                      radius: AppRadius.sm,
                      accentColor: accent,
                      isDark: isDark,
                      showBorder: true,
                      borderColor: accent.withValues(alpha: 0.18),
                      borderWidth: 1,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        section.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.titleMedium.copyWith(
                          fontSize: 16,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimaryLight,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.brandPrimary,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
            if (section.isSensitive) ...[
              const SizedBox(height: AppSpacing.sm),
              _SensitiveNotice(
                text: section.noticeText.trim().isNotEmpty
                    ? section.noticeText.trim()
                    : '请避免泄露个人隐私、联系方式或未经核实的信息',
                isDark: isDark,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SensitiveNotice extends StatelessWidget {
  final String text;
  final bool isDark;

  const _SensitiveNotice({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.warningSurfaceDark
            : AppColors.warningSurfaceLight,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: isDark ? 0.32 : 0.24),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: AppColors.warning,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.labelMedium.copyWith(
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
