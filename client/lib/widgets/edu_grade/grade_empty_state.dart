import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Page state for the grade screen.
enum GradePageState { loading, content, empty, error }

/// Empty, loading, and error states for the grade page.
class GradeEmptyState extends StatelessWidget {
  final GradePageState state;
  final String? errorMessage;
  final VoidCallback? onRetry;
  final bool
      isFilterEmpty; // true = filter produced no results, false = no grades at all

  const GradeEmptyState({
    super.key,
    required this.state,
    this.errorMessage,
    this.onRetry,
    this.isFilterEmpty = false,
  });

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case GradePageState.loading:
        return const _GradeLoadingSkeleton();
      case GradePageState.empty:
        return _buildEmpty(context);
      case GradePageState.error:
        return _buildError(context);
      case GradePageState.content:
        return const SizedBox.shrink();
    }
  }

  Widget _buildEmpty(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 64, color: isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight),
          const SizedBox(height: 16),
          Text(
            isFilterEmpty ? '该筛选条件下暂无课程' : '当前学期暂无成绩',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isFilterEmpty ? '请尝试切换其他筛选条件' : '本学期可能暂未录入成绩\n请稍后刷新或切换其他学期',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 64, color: isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight),
          const SizedBox(height: 16),
          Text(
            '成绩获取失败',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            errorMessage ?? '教务登录可能已经过期',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 24),
          if (onRetry != null)
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重新加载'),
            ),
        ],
      ),
    );
  }
}

class _GradeLoadingSkeleton extends StatefulWidget {
  const _GradeLoadingSkeleton();

  @override
  State<_GradeLoadingSkeleton> createState() => _GradeLoadingSkeletonState();
}

class _GradeLoadingSkeletonState extends State<_GradeLoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? AppColors.surfaceMutedDark : AppColors.surfaceMutedLight;
    final highlightColor = isDark ? AppColors.surfaceFocusedDark : AppColors.surfaceFocusedLight;

    return AnimatedBuilder(
      animation: _animation,
      builder: (context, _) {
        final color = Color.lerp(baseColor, highlightColor, _animation.value) ?? baseColor;

        Widget shimmerBox(double width, double height) {
          return Container(
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              // Semester selector skeleton
              shimmerBox(double.infinity, 60),
              const SizedBox(height: 16),
              // Summary card skeleton
              shimmerBox(double.infinity, 120),
              const SizedBox(height: 16),
              // Filter chips skeleton
              Row(
                children: [
                  shimmerBox(64, 32),
                  const SizedBox(width: 8),
                  shimmerBox(72, 32),
                  const SizedBox(width: 8),
                  shimmerBox(72, 32),
                ],
              ),
              const SizedBox(height: 16),
              // 4 course row skeletons
              ...List.generate(
                4,
                (_) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: shimmerBox(double.infinity, 56),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
