import 'dart:math' as math;

/// 液态导航物体的交互阶段。
enum LiquidNavPhase {
  idle,
  pressing,
  dragging,
  settling,
  collapsing,
}

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
  double lensCenterX = 0;
  double trackLeft = 0;
  double trackRight = 0;
  double itemWidth = 1;
  double velocity = 0;
  double edgeCompression = 0;
  bool isDragging = false;
  int? targetIndex;

  /// 以首个 Tab 的中心为轨道起点，统一维护 px 与 item position 的映射。
  double get visualPosition => position;

  void configureTrack({
    required double itemWidth,
    required double trackLeft,
    required double trackRight,
  }) {
    this.itemWidth = itemWidth;
    this.trackLeft = trackLeft;
    this.trackRight = trackRight;
    lensCenterX = centerForPosition(position);
  }

  double centerForPosition(double value) {
    if (itemWidth <= 0) return trackLeft;
    return trackLeft + value * itemWidth;
  }

  double positionForCenter(double centerX) {
    if (itemWidth <= 0) return position;
    return (centerX - trackLeft) / itemWidth;
  }

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
    lensCenterX = centerForPosition(position);
  }

  /// 直接接收 pointer 映射后的位置，不做插值和量化。
  void updateDrag({
    required double rawPosition,
    required double velocityPixelsPerSecond,
  }) {
    assert(isDragging);
    position = _clampPosition(rawPosition);
    lensCenterX = centerForPosition(position);
    edgeCompression = (rawPosition - position).abs().clamp(0.0, 0.72) / 0.72;
    velocity = velocityPixelsPerSecond;
  }

  /// 根据 Lens 的物理中心更新连续位置。中心可以短暂越过轨道边界，
  /// position 仍由控制器负责 clamp，而 edgeCompression 保留越界程度。
  void updateDragFromCenter({
    required double centerX,
    required double velocityPixelsPerSecond,
  }) {
    assert(isDragging);
    final rawPosition = positionForCenter(centerX);
    updateDrag(
      rawPosition: rawPosition,
      velocityPixelsPerSecond: velocityPixelsPerSecond,
    );
    lensCenterX = centerForPosition(position);
  }

  int endDrag({
    required double velocityPixelsPerSecond,
    required double itemWidth,
  }) {
    assert(isDragging);
    isDragging = false;
    velocity = velocityPixelsPerSecond;

    final nearest = position.round();
    final velocityInItemsPerSecond =
        itemWidth <= 0 ? 0.0 : velocityPixelsPerSecond / itemWidth;
    final projectedPosition = position + velocityInItemsPerSecond * 0.10;
    final projectedTarget = projectedPosition.round();
    final target = velocityPixelsPerSecond.abs() >= 450
        ? projectedTarget.clamp(
            velocityPixelsPerSecond > 0
                ? position.floor()
                : position.ceil() - 1,
            velocityPixelsPerSecond > 0
                ? position.floor() + 1
                : position.ceil(),
          )
        : nearest;
    targetIndex = target.clamp(0, itemCount - 1);

    // SpringSimulation 的速度单位是“位置单位/秒”，而控制器对外暴露
    // 的 velocity 使用 px/s，调用方在启动弹簧时再按 itemWidth 换算。
    if (itemWidth <= 0) velocity = 0;
    return targetIndex!;
  }

  void settle(double settledPosition) {
    position = _clampPosition(settledPosition);
    lensCenterX = centerForPosition(position);
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
