import 'dart:math' as math;

/// 液态表面的视觉滞后预算。
///
/// 业务导航位置仍然由 BottomNavController 立即更新；这个文件只计算玻璃
/// 表面要追随到哪里，避免把输入延迟误当成视觉重量。滞后限制在 2~6px
/// 的常见拖拽速度范围内，并在释放后由调用方继续收敛到逻辑位置。
const liquidGlassSurfaceLagSeconds = 0.004;
const liquidGlassSurfaceMaxLagPixels = 6.0;

double liquidGlassSurfaceTargetPosition({
  required double logicalPosition,
  required double velocityPixelsPerSecond,
  required double itemWidth,
  required bool dragging,
  required bool reduceMotion,
}) {
  if (!dragging || reduceMotion || itemWidth <= 0) return logicalPosition;

  final lagPixels = (-velocityPixelsPerSecond * liquidGlassSurfaceLagSeconds)
      .clamp(
        -liquidGlassSurfaceMaxLagPixels,
        liquidGlassSurfaceMaxLagPixels,
      )
      .toDouble();
  return logicalPosition + lagPixels / itemWidth;
}

double liquidGlassSurfacePositionFor({
  required double logicalPosition,
  required double previousPosition,
  required double velocityPixelsPerSecond,
  required double itemWidth,
  required bool dragging,
  required bool reduceMotion,
}) {
  if (reduceMotion) return logicalPosition;

  final target = liquidGlassSurfaceTargetPosition(
    logicalPosition: logicalPosition,
    velocityPixelsPerSecond: velocityPixelsPerSecond,
    itemWidth: itemWidth,
    dragging: dragging,
    reduceMotion: reduceMotion,
  );

  // 拖拽中快速跟随，但保留几像素的反向滞后；松手后降低响应率，形成
  // 一小段可中断的表面回弹，而不会拖慢业务位置或命中区域。
  final response = dragging ? 0.72 : 0.44;
  return previousPosition + (target - previousPosition) * response;
}

double liquidGlassSurfaceLagPixels({
  required double logicalPosition,
  required double surfacePosition,
  required double itemWidth,
}) {
  if (itemWidth <= 0) return 0;
  return (surfacePosition - logicalPosition) * itemWidth;
}

double clampLiquidGlassSurfacePosition(double value, int itemCount) {
  return value.clamp(0.0, math.max(0, itemCount - 1)).toDouble();
}
