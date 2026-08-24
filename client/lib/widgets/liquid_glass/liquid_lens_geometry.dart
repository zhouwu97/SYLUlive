import 'dart:math' as math;

import 'package:flutter/material.dart';

/// V8 的选中 Lens 只有一个几何语义：普通 Capsule / Stadium。
///
/// `speed`、`direction` 和 `edgeCompression` 参数暂时保留在公开 helper 上，
/// 以兼容 QA 页面与旧测试；它们现在只影响尺寸与 shader 光学，不再改变轮廓。
double liquidLensWidthFor({
  required double itemWidth,
  required double speed,
  required double edgeCompression,
  double widthScale = 1.0,
}) {
  return math.max(1.0, itemWidth * widthScale);
}

/// 生成与 AndroidLiquidGlass `Capsule()` 对应的圆角矩形路径。
class LiquidLensShape {
  const LiquidLensShape._();

  /// 仅作为旧 QA 配置的兼容字段；生产路径不再使用 superellipse exponent。
  static const exponent = 2.0;

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
    final rect = Offset.zero & Size(width, height);
    return Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          rect,
          Radius.circular(math.min(width, height) * 0.5),
        ),
      );
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

/// shader 降级路径使用的 Capsule capture clipper。
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
