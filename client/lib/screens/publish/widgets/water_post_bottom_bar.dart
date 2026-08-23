import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_radius.dart';
import '../../../theme/app_spacing.dart';

/// 发布页底部动作区。图片计数属于媒体区，底部只保留字数和主动作。
class WaterPostBottomBar extends StatelessWidget {
  final bool isLoading;
  final int charCount;
  final int maxContentLength;
  final String publishLabel;
  final VoidCallback? onPublish;

  const WaterPostBottomBar({
    super.key,
    required this.isLoading,
    required this.charCount,
    required this.maxContentLength,
    required this.publishLabel,
    required this.onPublish,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final compact = MediaQuery.viewInsetsOf(context).bottom > 0;
    final counter = Text(
      '$charCount/$maxContentLength字',
      style: TextStyle(
        fontSize: 12,
        color:
            isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
      ),
    );
    final button = SizedBox(
      height: compact ? 44 : 48,
      width: compact ? 132 : double.infinity,
      child: FilledButton(
        onPressed: isLoading ? null : onPublish,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.brandPrimary,
          foregroundColor: Colors.white,
          disabledBackgroundColor:
              AppColors.brandPrimary.withValues(alpha: 0.48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
        ),
        child: isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                publishLabel,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
              ),
      ),
    );

    return SafeArea(
      top: false,
      child: Container(
        color: isDark
            ? AppColors.surfacePrimaryDark
            : AppColors.surfacePrimaryLight,
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          compact ? AppSpacing.xs : AppSpacing.sm,
          AppSpacing.lg,
          compact ? AppSpacing.xs : AppSpacing.sm,
        ),
        child: compact
            ? Row(
                children: [
                  counter,
                  const Spacer(),
                  button,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  counter,
                  const SizedBox(height: AppSpacing.xs),
                  button,
                ],
              ),
      ),
    );
  }
}
