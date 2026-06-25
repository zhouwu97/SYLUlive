import 'package:flutter/material.dart';

/// Page state for the grade screen.
enum GradePageState { loading, content, empty, error }

/// Empty, loading, and error states for the grade page.
/// Does NOT depend on any shimmer package — uses plain Container + AnimatedOpacity.
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
        return _buildSkeleton(context);
      case GradePageState.empty:
        return _buildEmpty(context);
      case GradePageState.error:
        return _buildError(context);
      case GradePageState.content:
        return const SizedBox.shrink();
    }
  }

  Widget _buildSkeleton(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseColor = isDark ? Colors.grey[800]! : Colors.grey[200]!;
    final highlightColor = isDark ? Colors.grey[700]! : Colors.grey[100]!;

    Widget shimmerBox(double width, double height) {
      return _AnimatedShimmerBox(
        width: width,
        height: height,
        baseColor: baseColor,
        highlightColor: highlightColor,
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
                  )),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            isFilterEmpty ? '该筛选条件下暂无课程' : '暂无成绩',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            isFilterEmpty ? '请尝试切换其他筛选条件' : '本学期可能暂未录入成绩\n请稍后刷新或切换其他学期',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          const Text(
            '成绩加载失败',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            errorMessage ?? '教务登录可能已经过期',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
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

/// A simple animated placeholder box — no shimmer package dependency.
class _AnimatedShimmerBox extends StatefulWidget {
  final double width;
  final double height;
  final Color baseColor;
  final Color highlightColor;

  const _AnimatedShimmerBox({
    required this.width,
    required this.height,
    required this.baseColor,
    required this.highlightColor,
  });

  @override
  State<_AnimatedShimmerBox> createState() => _AnimatedShimmerBoxState();
}

class _AnimatedShimmerBoxState extends State<_AnimatedShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final color = Color.lerp(
          widget.baseColor,
          widget.highlightColor,
          _animation.value,
        )!;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
        );
      },
    );
  }
}
