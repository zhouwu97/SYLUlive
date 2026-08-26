import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Kyant DefaultHighlight 的 Flutter 绘制层。
///
/// 生产态只画一条 0.8px 左右的曲面高光，光照强度由 rounded-rect 法线与
/// 45° 入射方向的点积决定；不再用 Halo/Rim 叠加多圈白色描边。
class LiquidGlassDefaultHighlightPainter extends CustomPainter {
  const LiquidGlassDefaultHighlightPainter({
    required this.shader,
    required this.progress,
    required this.strength,
    required this.highContrast,
    required this.cornerRadius,
  });

  final ui.FragmentShader? shader;
  final double progress;
  final double strength;
  final bool highContrast;
  final double cornerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final alpha = 0.50 *
        progress.clamp(0.0, 1.0).toDouble() *
        strength.clamp(0.0, 1.0).toDouble();
    if (alpha <= 0.0001) return;

    final radius = cornerRadius.clamp(0.0, size.shortestSide / 2).toDouble();
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 1.0 : 0.8
      ..strokeCap = StrokeCap.round
      ..blendMode = BlendMode.plus
      ..color = Colors.white.withValues(alpha: alpha)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        highContrast ? 0.45 : 0.30,
      );

    final fragment = shader;
    if (fragment != null) {
      fragment
        ..setFloat(0, size.width)
        ..setFloat(1, size.height)
        ..setFloat(2, radius)
        ..setFloat(3, radius)
        ..setFloat(4, radius)
        ..setFloat(5, radius)
        ..setFloat(6, 1.0)
        ..setFloat(7, 1.0)
        ..setFloat(8, 1.0)
        ..setFloat(9, 1.0)
        ..setFloat(10, 45 * 3.141592653589793 / 180)
        ..setFloat(11, 1.0);
      paint.shader = fragment;
    }
    canvas.drawRRect(rrect.deflate(paint.strokeWidth / 2), paint);
  }

  @override
  bool shouldRepaint(covariant LiquidGlassDefaultHighlightPainter oldDelegate) {
    return oldDelegate.shader != shader ||
        oldDelegate.progress != progress ||
        oldDelegate.strength != strength ||
        oldDelegate.highContrast != highContrast ||
        oldDelegate.cornerRadius != cornerRadius;
  }
}
