import 'dart:math' as math;
import 'dart:ui' as ui;

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
    required this.refraction,
    required this.chromatic,
    required this.speed,
    required this.direction,
    required this.dockRefraction,
    required this.dockChromatic,
    required this.dockRecoilX,
  });

  final double interactionProgress;
  final double opticalActivation;
  final double refraction;
  final double chromatic;
  final double speed;
  final double direction;
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
          .clamp(0.0, 0.20)
          .toDouble();
  // 边界继续拖拽时 position 已被 clamp，额外保留一段弹性形变，保证首尾
  // Tab 向左、向右都能给出明确反馈，而不是像“拖不动”一样没有动效。
  final edgeIntensity = edgeCompression.clamp(0.0, 1.0).toDouble() * 0.14;
  final intensity = (velocityIntensity + edgeIntensity).clamp(0.0, 0.34);

  return LiquidGlassDragDeformation(
    intensity: intensity,
    direction: velocityPixelsPerSecond.abs() < 0.01
        ? 0.0
        : velocityPixelsPerSecond.sign,
    // 横向拉伸、纵向压扁是一组互补参数，左右方向共享同一力度。
    horizontalScale: 1.0 / math.max(0.70, 1.0 - intensity * 0.75),
    verticalScale: 1.0 - intensity * 0.25,
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
}) {
  final interactionProgress = _clamp01(activation);
  final speed = reduceMotion
      ? 0.0
      : (velocityPixelsPerSecond.abs() /
              math.max(tuning.velocityNormalization, 1.0))
          .clamp(0.0, 1.0)
          .toDouble();
  final direction = speed < 0.01 ? 0.0 : velocityPixelsPerSecond.sign;
  // 默认 idle 是 frosted glass；idleOpticalActivation 仅作为 QA/实验开关，
  // 让生产默认不会在没有交互时持续渲染液态折射。
  final idleActivation =
      tuning.idleOpticalActivation.clamp(0.0, 1.0).toDouble();

  final opticalActivation = switch (phase) {
    LiquidNavPhase.idle => idleActivation,
    LiquidNavPhase.pressing => ui.lerpDouble(
        idleActivation,
        1.0,
        0.72 + interactionProgress * 0.28,
      )!,
    LiquidNavPhase.dragging => 1.0,
    LiquidNavPhase.settling => ui.lerpDouble(
        idleActivation,
        1.0,
        interactionProgress,
      )!,
    LiquidNavPhase.collapsing => ui.lerpDouble(
        idleActivation,
        1.0,
        interactionProgress,
      )!,
  };

  final refractionScale = switch (phase) {
    LiquidNavPhase.idle => tuning.idleRefractionScale,
    LiquidNavPhase.pressing => ui.lerpDouble(
        tuning.idleRefractionScale,
        tuning.pressedRefractionScale,
        interactionProgress,
      )!,
    LiquidNavPhase.dragging => ui.lerpDouble(
        tuning.pressedRefractionScale,
        tuning.dragRefractionScale,
        speed,
      )!,
    LiquidNavPhase.settling => tuning.pressedRefractionScale,
    LiquidNavPhase.collapsing => ui.lerpDouble(
        tuning.pressedRefractionScale,
        tuning.idleRefractionScale,
        1.0 - interactionProgress,
      )!,
  };

  final chromaticScale = switch (phase) {
    LiquidNavPhase.idle => tuning.idleChromaticScale,
    LiquidNavPhase.pressing => ui.lerpDouble(
        tuning.idleChromaticScale,
        tuning.pressedChromaticScale,
        interactionProgress,
      )!,
    LiquidNavPhase.dragging => ui.lerpDouble(
        tuning.pressedChromaticScale,
        tuning.dragChromaticScale,
        speed,
      )!,
    LiquidNavPhase.settling => tuning.pressedChromaticScale,
    LiquidNavPhase.collapsing => ui.lerpDouble(
        tuning.pressedChromaticScale,
        tuning.idleChromaticScale,
        1.0 - interactionProgress,
      )!,
  };

  final velocityRefractionBoost = 1.0 + speed * 0.35;
  final velocityChromaticBoost = 1.0 + speed * 0.18;
  final refraction = tuning.effectiveRefraction *
      refractionScale.clamp(0.0, 3.0) *
      velocityRefractionBoost;
  final chromatic = tuning.effectiveChromatic *
      chromaticScale.clamp(0.0, 3.0) *
      velocityChromaticBoost;

  final dockActivation = opticalActivation.clamp(0.0, 1.0).toDouble();
  final dockRefraction = tuning.dockRefraction *
      ui.lerpDouble(0.78, 1.0, dockActivation)! *
      (1.0 + speed * 0.18);
  final dockChromatic = tuning.dockChromatic *
      ui.lerpDouble(0.72, 1.0, dockActivation)! *
      (1.0 + speed * 0.16);

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
    refraction: refraction,
    chromatic: chromatic,
    speed: speed,
    direction: direction,
    dockRefraction: dockRefraction,
    dockChromatic: dockChromatic,
    dockRecoilX: dockRecoilX,
  );
}

double _clamp01(double value) => value.clamp(0.0, 1.0).toDouble();
