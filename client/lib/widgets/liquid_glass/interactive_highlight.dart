import 'package:flutter/material.dart';

/// Kyant InteractiveHighlight 的 Flutter 版本。
///
/// 它只负责按压后的整块白光与 pointer radial；玻璃曲面本身的常驻反光由
/// LiquidGlassDefaultHighlightPainter 独立负责，两个概念不再互相替代。
class LiquidGlassInteractiveHighlightPainter extends CustomPainter {
  const LiquidGlassInteractiveHighlightPainter({
    required this.center,
    required this.progress,
    required this.radiusScale,
    required this.strength,
    required this.highContrast,
  });

  final Offset center;
  final double progress;
  final double radiusScale;
  final double strength;
  final bool highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final factor = progress.clamp(0.0, 1.0).toDouble() *
        strength.clamp(0.0, 1.0).toDouble();
    if (factor <= 0.0001) return;

    final contrastScale = highContrast ? 1.12 : 1.0;
    // 原版先铺一层整块 White(0.08)，BlendMode.Plus。
    final basePaint = Paint()
      ..blendMode = BlendMode.plus
      ..color = Colors.white.withValues(alpha: 0.08 * factor * contrastScale);
    canvas.drawRect(Offset.zero & size, basePaint);

    // 再叠加跟随 pointer 的 White(0.15) radial，半径为最小边的 1.5 倍。
    final radius = size.shortestSide * radiusScale;
    final safeCenter = Offset(
      center.dx.clamp(0.0, size.width).toDouble(),
      center.dy.clamp(0.0, size.height).toDouble(),
    );
    final radialRect = Rect.fromCircle(center: safeCenter, radius: radius);
    final radialPaint = Paint()
      ..blendMode = BlendMode.plus
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(
            alpha: 0.15 * factor * contrastScale,
          ),
          Colors.white.withValues(
            alpha: 0.15 * factor * contrastScale * 0.22,
          ),
          Colors.transparent,
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(radialRect);
    canvas.drawRect(Offset.zero & size, radialPaint);
  }

  @override
  bool shouldRepaint(
      covariant LiquidGlassInteractiveHighlightPainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.progress != progress ||
        oldDelegate.radiusScale != radiusScale ||
        oldDelegate.strength != strength ||
        oldDelegate.highContrast != highContrast;
  }
}
