import 'package:flutter/material.dart';

/// Fixed bottom publish bar.
///
/// Commit 1: placeholder — returns [SizedBox.shrink].
/// Commit 2: full implementation with SafeArea, loading state, and keyboard
/// avoidance.
class PublishBottomBar extends StatelessWidget {
  final bool isLoading;
  final VoidCallback? onPressed;
  final String label;

  const PublishBottomBar({
    super.key,
    required this.isLoading,
    this.onPressed,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    // Placeholder – will be implemented in Commit 2.
    return const SizedBox.shrink();
  }
}
