import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import 'app_card.dart';

/// 帖子加载、失败和不存在共用内容底面，状态切换时保持尺寸和材质。
class PostStatusSurface extends StatelessWidget {
  const PostStatusSurface({
    super.key,
    required this.isLoading,
    required this.onRetry,
    this.error,
    this.loadingMessage = '正在加载帖子…',
    this.emptyMessage = '帖子不存在',
  });

  final bool isLoading;
  final VoidCallback onRetry;
  final String? error;
  final String loadingMessage;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: AppCardSurface(
        key: const ValueKey('post-status-surface'),
        padding: const EdgeInsets.all(AppSpacing.xxl),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isDark
              ? AppColors.surfaceSecondaryDark
              : AppColors.surfaceSecondaryLight,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: AppSpacing.lg),
                Text(loadingMessage, textAlign: TextAlign.center),
              ] else if (error != null) ...[
                Icon(Icons.cloud_off, size: 48, color: colors.onSurfaceVariant),
                const SizedBox(height: AppSpacing.lg),
                Text(error!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: colors.onSurfaceVariant)),
                const SizedBox(height: AppSpacing.lg),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重试'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    visualDensity: VisualDensity.standard,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                  ),
                ),
              ] else
                Text(emptyMessage,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(color: colors.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
