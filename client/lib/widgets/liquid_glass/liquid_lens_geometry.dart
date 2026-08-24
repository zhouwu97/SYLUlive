import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 计算可见 Lens 宽度，同时不改变其跟踪中心。
double liquidLensWidthFor({
  required double itemWidth,
  required double speed,
  required double edgeCompression,
  double widthScale = 1.52,
}) {
  final baseWidth = math.max(84.0, itemWidth * widthScale);
  final normalizedSpeed = speed.clamp(0.0, 1.0).toDouble();
  final stretch = math.min(1.08, 1.0 + normalizedSpeed * 0.08);
  final edge = edgeCompression.clamp(0.0, 1.0).toDouble();
  return baseWidth * stretch * (1.0 - edge * 0.04);
}

/// Shape Only QA 与降级路径共用的唯一 CPU 几何模型。
///
/// 曲线由参数化 superellipse 与 cubic Hermite 片段生成，不使用折线或独立拼装
/// 的圆角，因此可见轮廓保持 C1 连续，shader 也能解析计算对应的隐式曲面。
class LiquidLensShape {
  const LiquidLensShape._();

  static const exponent = 2.15;

  static Path pathForSize(
    Size size, {
    required double speed,
    required double direction,
    required double edgeCompression,
    double lensExponent = exponent,
    double flowStrength = 0.72,
  }) {
    final width = math.max(size.width, 1.0);
    final height = math.max(size.height, 1.0);
    final motion = speed.clamp(0.0, 1.0).toDouble();
    final sign = direction < -0.01 ? -1.0 : 1.0;
    final edge = edgeCompression.clamp(0.0, 1.0).toDouble();
    final exponentValue = lensExponent.clamp(2.02, 3.5).toDouble();
    final flow = flowStrength.clamp(0.0, 1.4).toDouble();
    final halfHeight = height * 0.5;
    final tail = halfHeight * motion * 0.45 * flow;
    final bulge = halfHeight * motion * 0.28 * flow;
    final compression = halfHeight * edge * 0.16 * flow;
    final halfWidth = math.max(
      width * 0.5 - math.max(tail, bulge - compression),
      halfHeight * 0.72,
    );

    double smoothstep(double value) {
      final t = value.clamp(0.0, 1.0).toDouble();
      return t * t * (3 - 2 * t);
    }

    Offset pointAt(double angle) {
      final cosine = math.cos(angle);
      final sine = math.sin(angle);
      final normalizedY = sine.abs().clamp(0.0, 1.0);
      final yPower = math.pow(normalizedY, exponentValue).toDouble();
      final baseFactor =
          math.pow(math.max(1 - yPower, 0.0), 1 / exponentValue).toDouble();
      final baseExtent = halfWidth * baseFactor;
      final profile = 1 - smoothstep(normalizedY);
      final leftExtent = baseExtent + tail * profile;
      final rightExtent = baseExtent + (bulge - compression) * profile;
      final centerShift = (rightExtent - leftExtent) * 0.5;
      final halfExtent = math.max((leftExtent + rightExtent) * 0.5, 0.001);
      final normalizedX =
          cosine.sign * math.pow(cosine.abs(), 2 / exponentValue).toDouble();
      final canonicalX = centerShift + normalizedX * halfExtent;
      return Offset(
        width * 0.5 + canonicalX * sign,
        height * 0.5 +
            sine.sign *
                halfHeight *
                math.pow(normalizedY, 2 / exponentValue).toDouble(),
      );
    }

    Offset tangentAt(double angle, double delta) {
      final before = pointAt(angle - delta);
      final after = pointAt(angle + delta);
      return (after - before) / (2 * delta);
    }

    const segments = 64;
    const step = math.pi * 2 / segments;
    final path = Path()..moveTo(pointAt(0).dx, pointAt(0).dy);

    Offset boundedControl(Offset point) {
      return Offset(
        point.dx.clamp(0.0, width).toDouble(),
        point.dy.clamp(0.0, height).toDouble(),
      );
    }

    for (var index = 0; index < segments; index++) {
      final startAngle = index * step;
      final endAngle = (index + 1) * step;
      final start = pointAt(startAngle);
      final end = pointAt(endAngle);
      final startTangent = tangentAt(startAngle, step * 0.22);
      final endTangent = tangentAt(endAngle, step * 0.22);
      final firstControl = boundedControl(
        Offset(
          start.dx + startTangent.dx * step / 3,
          start.dy + startTangent.dy * step / 3,
        ),
      );
      final secondControl = boundedControl(
        Offset(
          end.dx - endTangent.dx * step / 3,
          end.dy - endTangent.dy * step / 3,
        ),
      );
      path.cubicTo(
        firstControl.dx,
        firstControl.dy,
        secondControl.dx,
        secondControl.dy,
        end.dx,
        end.dy,
      );
    }
    return path..close();
  }
}

class LiquidLensClipper extends CustomClipper<Path> {
  const LiquidLensClipper({
    required this.speed,
    required this.direction,
    required this.edgeCompression,
    this.lensExponent = LiquidLensShape.exponent,
    this.flowStrength = 0.72,
  });

  final double speed;
  final double direction;
  final double edgeCompression;
  final double lensExponent;
  final double flowStrength;

  @override
  Path getClip(Size size) => LiquidLensShape.pathForSize(
        size,
        speed: speed,
        direction: direction,
        edgeCompression: edgeCompression,
        lensExponent: lensExponent,
        flowStrength: flowStrength,
      );

  @override
  bool shouldReclip(covariant LiquidLensClipper oldClipper) {
    return oldClipper.speed != speed ||
        oldClipper.direction != direction ||
        oldClipper.edgeCompression != edgeCompression ||
        oldClipper.lensExponent != lensExponent ||
        oldClipper.flowStrength != flowStrength;
  }
}

/// 仅供降级路径使用的 clipper。shader 路径有意不使用这条边界；由于 blur filter
/// 没有光学 mask，降级路径才需要它。
class LiquidLensCaptureClipper extends CustomClipper<Path> {
  const LiquidLensCaptureClipper({
    required this.visibleOffset,
    required this.visibleSize,
    required this.speed,
    required this.direction,
    required this.edgeCompression,
    this.lensExponent = LiquidLensShape.exponent,
    this.flowStrength = 0.72,
  });

  final Offset visibleOffset;
  final Size visibleSize;
  final double speed;
  final double direction;
  final double edgeCompression;
  final double lensExponent;
  final double flowStrength;

  @override
  Path getClip(Size size) {
    return LiquidLensShape.pathForSize(
      visibleSize,
      speed: speed,
      direction: direction,
      edgeCompression: edgeCompression,
      lensExponent: lensExponent,
      flowStrength: flowStrength,
    ).shift(visibleOffset);
  }

  @override
  bool shouldReclip(covariant LiquidLensCaptureClipper oldClipper) {
    return oldClipper.visibleOffset != visibleOffset ||
        oldClipper.visibleSize != visibleSize ||
        oldClipper.speed != speed ||
        oldClipper.direction != direction ||
        oldClipper.edgeCompression != edgeCompression ||
        oldClipper.lensExponent != lensExponent ||
        oldClipper.flowStrength != flowStrength;
  }
}
