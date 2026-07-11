import 'package:flutter/material.dart';

class ExamPaperStatusBadge extends StatelessWidget {
  final String status;

  const ExamPaperStatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'pending' => ('待审核', Colors.orange.shade700),
      'published' => ('已通过', Colors.green.shade700),
      'unpublished' => ('已下架', Theme.of(context).colorScheme.outline),
      _ => (status, Theme.of(context).colorScheme.primary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
