import 'dart:math' as math;

import 'bottom_nav_controller.dart';
import 'liquid_glass_tuning.dart';

/// BottomNav 液态材质在一帧内使用的派生状态。
///
/// 交互阶段、速度、连续位置和调参 preset 在这里收敛为渲染层需要的数值。
/// 这样 selection、Dock 和高光不会各自解释“按压/拖动”的含义。
class LiquidGlassMotionState {
  const LiquidGlassMotionState({
    required this.interactionProgress,
    required this.opticalActivation,
    required this.highlightProgress,
    required this.refraction,
    required this.chromatic,
    required this.speed,
    required this.direction,
    required this.dockOpticalActivation,
    required this.dockRefraction,
    required this.dockChromatic,
    required this.dockRecoilX,
  });

  final double interactionProgress;
  final double opticalActivation;
  final double highlightProgress;
  final double refraction;
  final double chromatic;
  final double speed;
  final double direction;
  final double dockOpticalActivation;
  final double dockRefraction;
  final double dockChromatic;
  final double dockRecoilX;
}

/// 拖拽时 Lens 的几何形变参数。
///
/// 速度的绝对值只负责“拉伸/压扁”的力度，速度符号只负责光学流向。
/// 如果把带符号的速度直接乘进宽高，向左拖会变成收缩，表现为只有一边
/// 的液态形变生效。
class LiquidGlassDragDeformation {
  const LiquidGlassDragDeformation({
    required this.intensity,
    required this.direction,
    required this.horizontalScale,
    required this.verticalScale,
  });

  final double intensity;
  final double direction;
  final double horizontalScale;
  final double verticalScale;
}

LiquidGlassDragDeformation liquidGlassDragDeformationFor({
  required double velocityPixelsPerSecond,
  required double normalization,
  double edgeCompression = 0,
}) {
  final velocityIntensity =
      (velocityPixelsPerSecond.abs() / math.max(normalization, 1.0))
          .clamp(0.0, 0.08)
          .toDouble();
  // 边界继续拖拽时 position 已被 clamp，额外保留一段弹性形变，保证首尾
  // Tab 向左、向右都能给出明确反馈，而不是像“拖不动”一样没有动效。
  final edgeIntensity = edgeCompression.clamp(0.0, 1.0).toDouble() * 0.04;
  final intensity = (velocityIntensity + edgeIntensity).clamp(0.0, 0.12);

  return LiquidGlassDragDeformation(
    intensity: intensity,
    direction: velocityPixelsPerSecond.abs() < 0.01
        ? 0.0
        : velocityPixelsPerSecond.sign,
    // 横向拉伸、纵向压扁是一组互补参数，左右方向共享同一力度。
    horizontalScale: 1.0 + intensity * 0.58,
    verticalScale: 1.0 - intensity * 0.22,
  );
}

LiquidGlassMotionState liquidGlassMotionFor({
  required LiquidNavPhase phase,
  required double activation,
  required double velocityPixelsPerSecond,
  required double visualPosition,
  required int currentIndex,
  required double edgeCompression,
  required bool reduceMotion,
  required LiquidGlassTuning tuning,
  bool useLiquidGlass = true,
}) {
  final interactionProgress = _clamp01(activation);
  final speed = reduceMotion
      ? 0.0
      : (velocityPixelsPerSecond.abs() /
              math.max(tuning.velocityNormalization, 1.0))
          .clamp(0.0, 1.0)
          .toDouble();
  final direction = speed < 0.01 ? 0.0 : velocityPixelsPerSecond.sign;
  // Selection 只在 press / drag / settle 阶段打开 Lens；Dock 另有独立的
  // 常驻光学激活，不再把整块 Dock 绑定在这个值上。
  final idleActivation =
      tuning.idleOpticalActivation.clamp(0.0, 1.0).toDouble();

  final opticalActivation = switch (phase) {
    LiquidNavPhase.idle => idleActivation,
    LiquidNavPhase.pressing => interactionProgress,
    LiquidNavPhase.dragging => 1.0,
    LiquidNavPhase.settling => interactionProgress,
    LiquidNavPhase.collapsing => interactionProgress,
  };

  // Kyant 的 lens 参数由 pressProgress 直接控制；不再为每个阶段另造一
  // 套强度曲线。速度只作为轻微的光学跟随，主动力学交给独立 X/Y spring。
  final highlightProgress = opticalActivation;

  // 速度主要改变几何；光学增益只留很小的上限，避免拖拽时变成彩色
  // 闪烁。参考实现的重量来自独立的 scaleX/scaleY 与 lens，而不是把所有
  // uniform 都乘上速度。
  final velocityRefractionBoost = 1.0 + speed * 0.08;
  final velocityChromaticBoost = 1.0 + speed * 0.04;
  final refraction = tuning.effectiveRefraction *
      opticalActivation *
      velocityRefractionBoost;
  final chromatic = tuning.effectiveChromatic *
      opticalActivation *
      velocityChromaticBoost;

  final dockActivation = useLiquidGlass ? 1.0 : 0.0;
  final dockRefraction = tuning.dockRefraction * (1.0 + speed * 0.04);
  final dockChromatic = tuning.dockChromatic;

  final positionSignal =
      (visualPosition - currentIndex).clamp(-1.0, 1.0).toDouble();
  final edgeDirection = direction == 0 ? positionSignal.sign : direction;
  final recoilSignal = (positionSignal * 0.72 +
          edgeDirection * edgeCompression.clamp(0.0, 1.0) * 0.28)
      .clamp(-1.0, 1.0)
      .toDouble();
  final recoilPhase = switch (phase) {
    LiquidNavPhase.idle => 0.0,
    LiquidNavPhase.pressing => 0.35,
    LiquidNavPhase.dragging => 1.0,
    LiquidNavPhase.settling => 0.72,
    LiquidNavPhase.collapsing => 0.0,
  };
  final dockRecoilX = reduceMotion
      ? 0.0
      : recoilSignal *
          tuning.dockRecoilDistance *
          tuning.dockRecoilStrength.clamp(0.0, 1.0).toDouble() *
          recoilPhase;

  return LiquidGlassMotionState(
    interactionProgress: interactionProgress,
    opticalActivation: opticalActivation.clamp(0.0, 1.0).toDouble(),
    highlightProgress: highlightProgress.clamp(0.0, 1.0).toDouble(),
    refraction: refraction,
    chromatic: chromatic,
    speed: speed,
    direction: direction,
    dockOpticalActivation: dockActivation,
    dockRefraction: dockRefraction,
    dockChromatic: dockChromatic,
    dockRecoilX: dockRecoilX,
  );
}

double _clamp01(double value) => value.clamp(0.0, 1.0).toDouble();
