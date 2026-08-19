import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

class PollResultBar extends StatelessWidget {
  final double ratio;
  final Color color;

  const PollResultBar({
    super.key,
    required this.ratio,
    this.color = AppColors.brandPrimary,
  });

  @override
  Widget build(BuildContext context) {
    final value = ratio.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: color.withValues(alpha: 0.12)),
            AnimatedFractionallySizedBox(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.centerLeft,
              widthFactor: value,
              child: ColoredBox(color: color.withValues(alpha: 0.72)),
            ),
          ],
        ),
      ),
    );
  }
}
