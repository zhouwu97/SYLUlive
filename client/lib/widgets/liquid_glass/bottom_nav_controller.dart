import 'dart:math' as math;

/// 液态底栏的连续位置状态。
///
/// 页面提交状态仍由 HomeScreen 持有；这个控制器只描述 Dock 内的视觉
/// 物体。拖拽期间 position 是连续值，只有释放后才由 targetIndex 决定
/// 吸附到哪个入口。
class BottomNavController {
  BottomNavController({
    required this.itemCount,
    required int initialIndex,
  })  : assert(itemCount > 0),
        assert(initialIndex >= 0 && initialIndex < itemCount),
        position = initialIndex.toDouble();

  final int itemCount;

  double position;
  double velocity = 0;
  double edgeCompression = 0;
  bool isDragging = false;
  int? targetIndex;

  double get direction {
    if (velocity.abs() < 0.01) return 0;
    return velocity.sign;
  }

  void beginDrag(double startPosition) {
    isDragging = true;
    targetIndex = null;
    velocity = 0;
    edgeCompression = 0;
    position = _clampPosition(startPosition);
  }

  /// 直接接收 pointer 映射后的位置，不做插值和量化。
  void updateDrag({
    required double rawPosition,
    required double velocityPixelsPerSecond,
  }) {
    assert(isDragging);
    position = _clampPosition(rawPosition);
    edgeCompression = (rawPosition - position).abs().clamp(0.0, 0.72) / 0.72;
    velocity = velocityPixelsPerSecond;
  }

  int endDrag({
    required double velocityPixelsPerSecond,
    required double itemWidth,
  }) {
    assert(isDragging);
    isDragging = false;
    velocity = velocityPixelsPerSecond;

    final nearest = position.round();
    final isFlick = velocityPixelsPerSecond.abs() >= 450;
    final flickTarget = nearest + velocityPixelsPerSecond.sign.toInt();
    final target = isFlick ? flickTarget : nearest;
    targetIndex = target.clamp(0, itemCount - 1);

    // SpringSimulation 的速度单位是“位置单位/秒”，而控制器对外暴露
    // 的 velocity 使用 px/s，调用方在启动弹簧时再按 itemWidth 换算。
    if (itemWidth <= 0) velocity = 0;
    return targetIndex!;
  }

  void settle(double settledPosition) {
    position = _clampPosition(settledPosition);
    velocity = 0;
    edgeCompression = 0;
    isDragging = false;
    targetIndex = null;
  }

  void cancelDrag(double settledPosition) {
    settle(settledPosition);
  }

  double _clampPosition(double value) {
    return value.clamp(0.0, math.max(0, itemCount - 1)).toDouble();
  }
}
