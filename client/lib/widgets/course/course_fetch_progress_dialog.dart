import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../app_card.dart';

class CourseFetchProgressDialog extends StatelessWidget {
  const CourseFetchProgressDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 48, vertical: AppSpacing.xxl),
        child: AppCardSurface(
          key: const ValueKey('course-fetch-progress-surface'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sheet),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
                horizontal: 28, vertical: AppSpacing.section),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brandPrimary.withValues(alpha: .12),
                  ),
                  child: const CircularProgressIndicator(
                    color: AppColors.brandPrimary,
                    strokeWidth: 3,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text('正在从教务系统提取课表',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    )),
                const SizedBox(height: AppSpacing.sm),
                Text('请耐心等待，数据量较大时可能需要几秒…',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      decoration: TextDecoration.none,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
