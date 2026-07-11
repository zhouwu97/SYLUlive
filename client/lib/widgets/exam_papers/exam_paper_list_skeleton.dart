import 'package:flutter/material.dart';

class ExamPaperListSkeleton extends StatelessWidget {
  final EdgeInsetsGeometry padding;

  const ExamPaperListSkeleton({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
  });

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: padding,
      itemCount: 3,
      itemBuilder: (context, index) => Container(
        key: const ValueKey('exam-paper-skeleton-item'),
        height: 132,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: base),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SkeletonLine(widthFactor: 0.72, color: base),
            const SizedBox(height: 14),
            _SkeletonLine(widthFactor: 0.48, color: base),
            const Spacer(),
            _SkeletonLine(widthFactor: 0.62, color: base),
          ],
        ),
      ),
    );
  }
}

class _SkeletonLine extends StatelessWidget {
  final double widthFactor;
  final Color color;

  const _SkeletonLine({required this.widthFactor, required this.color});

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: 12,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}
