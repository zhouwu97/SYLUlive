import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lens 内跟随 pointer 的局部高光。
///
/// 高光只在已经存在的玻璃 clip 内绘制，不创建新的 BackdropFilter，也不
/// 参与手势命中；pointer 位置由 BottomNav 的局部 motion notifier 驱动。
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
    final intensity = (progress * strength).clamp(0.0, 1.0).toDouble();
    if (intensity <= 0.0001 || size.isEmpty) return;

    // 中心光斑只做 pointer 的局部折光提示；主要高光已经交给 Lens 四周
    // 的 edge halo，避免一按下就把整颗胶囊铺成白色。
    final radius = math.max(size.width, size.height) * radiusScale * 0.72;
    final safeCenter = Offset(
      center.dx.clamp(-radius, size.width + radius).toDouble(),
      center.dy.clamp(-radius, size.height + radius).toDouble(),
    );
    final alpha = (highContrast ? 0.16 : 0.09) * intensity;
    final glowRect = Rect.fromCircle(center: safeCenter, radius: radius);
    final glowPaint = Paint()
      ..blendMode = BlendMode.screen
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: alpha),
          Colors.white.withValues(alpha: alpha * 0.34),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.34, 1.0],
      ).createShader(glowRect);
    canvas.drawCircle(safeCenter, radius, glowPaint);

    // 一条很短的上左 specular，给 pointer 高光一个方向感，避免变成白色圆斑。
    final specularCenter =
        safeCenter + Offset(-size.width * 0.16, -size.height * 0.18);
    final specularRect = Rect.fromCenter(
      center: specularCenter,
      width: size.width * 0.42,
      height: math.max(2.0, size.height * 0.060),
    );
    final specularPaint = Paint()
      ..blendMode = BlendMode.screen
      ..shader = LinearGradient(
        colors: [
          Colors.transparent,
          Colors.white.withValues(alpha: alpha * 0.70),
          Colors.white.withValues(alpha: alpha * 0.20),
          Colors.transparent,
        ],
        stops: const [0.0, 0.34, 0.66, 1.0],
      ).createShader(specularRect);
    canvas.drawOval(specularRect, specularPaint);
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

/// Dock 外沿的弱彩色 specular；它与 Lens 高光分离，避免两层玻璃共用一圈白边。
class LiquidGlassDockSpecularPainter extends CustomPainter {
  const LiquidGlassDockSpecularPainter({
    required this.progress,
    required this.strength,
    required this.highContrast,
  });

  final double progress;
  final double strength;
  final bool highContrast;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final radius = math.min(size.width, size.height) / 2;
    final opticalProgress = progress.clamp(0.0, 1.0).toDouble();
    if (opticalProgress <= 0.0001) return;
    final alpha = (highContrast ? 0.48 : 0.22) *
        strength.clamp(0.0, 1.0) *
        (0.28 + opticalProgress * 0.72);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = highContrast ? 1.35 : 1.0
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: math.pi * 3 / 2,
        colors: [
          const Color(0xFF75E7FF).withValues(alpha: alpha * 1.10),
          const Color(0xFF9EA2FF).withValues(alpha: alpha * 0.86),
          const Color(0xFFFF8FCB).withValues(alpha: alpha * 0.80),
          const Color(0xFFFFD17F).withValues(alpha: alpha * 0.76),
          const Color(0xFF7CFFD5).withValues(alpha: alpha * 0.94),
          const Color(0xFF75E7FF).withValues(alpha: alpha * 1.10),
        ],
        stops: const [0, 0.20, 0.38, 0.58, 0.80, 1],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius)),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant LiquidGlassDockSpecularPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.strength != strength ||
        oldDelegate.highContrast != highContrast;
  }
}
