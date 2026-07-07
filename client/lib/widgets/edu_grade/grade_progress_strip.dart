import 'package:flutter/material.dart';

class GradeProgressStrip extends StatelessWidget {
  final int passed;
  final int failed;
  final int inProgress;
  final int notStarted;

  const GradeProgressStrip({
    super.key,
    required this.passed,
    required this.failed,
    required this.inProgress,
    required this.notStarted,
  });

  @override
  Widget build(BuildContext context) {
    final total = passed + failed + inProgress + notStarted;
    if (total <= 0) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 8,
          color: Theme.of(context).dividerColor.withValues(alpha: 0.18),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            _segment(context, passed / total, Colors.green),
            _segment(context, failed / total, Colors.red),
            _segment(context, inProgress / total, Colors.blueGrey),
            _segment(
              context,
              notStarted / total,
              Theme.of(context).dividerColor.withValues(alpha: 0.45),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, double flex, Color color) {
    if (flex <= 0) return const SizedBox.shrink();
    return Expanded(
      flex: (flex * 1000).round().clamp(1, 1000),
      child: ColoredBox(color: color.withValues(alpha: 0.72)),
    );
  }
}
