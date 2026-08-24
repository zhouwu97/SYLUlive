import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// 光学 QA 与生产渲染模式。
///
/// 每种模式只启用一组光学效果，便于 QA 页面将几何问题与材质问题拆开观察。
enum LiquidGlassQaMode {
  finalGlass,
  identity,
  coreOnly,
  refractionOnly,
  chromaticOnly,
  fresnelOnly,
  shapeOnly,
}

/// 底栏选中态的色彩情绪预设。
enum LiquidNavColorPreset {
  sylulive,
  coolapkReference,
}

/// 液态导航 Lens 的全部影响参数。
///
/// 可见 Lens 与 shader 捕获区域都由这个对象派生。参数集中后，Widget、shader
/// 和 QA 页面不会悄悄演变成三套不同的光学模型。
class LiquidGlassTuning {
  const LiquidGlassTuning({
    // V8 对齐 AndroidLiquidGlass：选中态始终是 Capsule，按压只改变
    // 尺度、边缘光学和内容缩放，不再切换成另一套自由曲面。
    this.lensExponent = 2.0,
    this.lensWidthScale = 1.0,
    this.lensHeight = 56.0,
    this.pressedScale = 78.0 / 56.0,
    this.overscanX = 18.0,
    this.overscanY = 16.0,
    this.refractionHeight = 10.0,
    this.refraction = 14.0,
    this.verticalRefractionScale = 1.0,
    this.refractionBandStart = 0.60,
    this.refractionBandPeak = 0.80,
    this.refractionBandEnd = 0.92,
    // 保留字段以兼容 QA 配置文件；V8 shader 不再使用中心放大。
    this.magnification = 1.0,
    this.magnificationRadius = 0.66,
    this.chromatic = 1.0,
    this.chromaticStart = 0.84,
    this.rimStrength = 0.12,
    this.lightStrength = 0.20,
    this.velocityNormalization = 1000.0,
    this.flowStrength = 0.72,
    this.dockAlpha = 0.40,
    this.dockBlur = 8.0,
    this.dockLensHeight = 24.0,
    this.dockLensAmount = 24.0,
    this.mode = LiquidGlassQaMode.finalGlass,
    this.colorPreset = LiquidNavColorPreset.sylulive,
    this.showCaptureBounds = false,
  });

  /// 克制的材质预设，用于在弱光学畸变下对比几何轮廓。
  static const natural = LiquidGlassTuning(
    refraction: 10.0,
    chromatic: 0.70,
  );

  /// 按用户提供的酷安截图调出的默认参考预设。
  static const coolapk = LiquidGlassTuning(
    colorPreset: LiquidNavColorPreset.coolapkReference,
  );

  /// 有意增强的 QA 预设，生产环境不使用。
  static const strong = LiquidGlassTuning(
    refraction: 18.0,
    chromatic: 1.35,
  );

  final double lensExponent;
  final double lensWidthScale;
  final double lensHeight;
  final double pressedScale;
  final double overscanX;
  final double overscanY;

  /// Explicit AGSL `refractionHeight`; it is not derived from Capsule height.
  final double refractionHeight;
  final double refraction;
  final double verticalRefractionScale;
  final double refractionBandStart;
  final double refractionBandPeak;
  final double refractionBandEnd;

  final double magnification;
  final double magnificationRadius;

  final double chromatic;
  final double chromaticStart;

  final double rimStrength;
  final double lightStrength;
  final double velocityNormalization;
  final double flowStrength;

  final double dockAlpha;
  final double dockBlur;
  final double dockLensHeight;
  final double dockLensAmount;
  final LiquidGlassQaMode mode;
  final LiquidNavColorPreset colorPreset;
  final bool showCaptureBounds;

  Color focusColorFor(bool isDark) {
    switch (colorPreset) {
      case LiquidNavColorPreset.sylulive:
        return isDark ? const Color(0xFF72D5C6) : AppColors.brandPrimary;
      case LiquidNavColorPreset.coolapkReference:
        return isDark ? const Color(0xFFF0C978) : const Color(0xFFE7BC70);
    }
  }

  Color focusPressedColorFor(bool isDark) {
    final focus = focusColorFor(isDark);
    switch (colorPreset) {
      case LiquidNavColorPreset.sylulive:
        return Color.lerp(focus, const Color(0xFFBCEDE4), 0.24)!;
      case LiquidNavColorPreset.coolapkReference:
        return Color.lerp(focus, const Color(0xFFF7DCA3), 0.24)!;
    }
  }

  double get effectiveRefraction {
    switch (mode) {
      case LiquidGlassQaMode.finalGlass:
      case LiquidGlassQaMode.refractionOnly:
        return refraction;
      case LiquidGlassQaMode.identity:
      case LiquidGlassQaMode.coreOnly:
      case LiquidGlassQaMode.chromaticOnly:
      case LiquidGlassQaMode.fresnelOnly:
      case LiquidGlassQaMode.shapeOnly:
        return 0;
    }
  }

  double get effectiveRefractionHeight {
    switch (mode) {
      case LiquidGlassQaMode.finalGlass:
      case LiquidGlassQaMode.refractionOnly:
        return refractionHeight;
      case LiquidGlassQaMode.identity:
      case LiquidGlassQaMode.coreOnly:
      case LiquidGlassQaMode.chromaticOnly:
      case LiquidGlassQaMode.fresnelOnly:
      case LiquidGlassQaMode.shapeOnly:
        return 0;
    }
  }

  double get effectiveMagnification {
    // 中央区域直接采样原图；图标放大由真实 UI layer 完成。
    return 1;
  }

  double get effectiveChromatic {
    switch (mode) {
      case LiquidGlassQaMode.finalGlass:
      case LiquidGlassQaMode.chromaticOnly:
        return chromatic;
      case LiquidGlassQaMode.identity:
      case LiquidGlassQaMode.coreOnly:
      case LiquidGlassQaMode.refractionOnly:
      case LiquidGlassQaMode.fresnelOnly:
      case LiquidGlassQaMode.shapeOnly:
        return 0;
    }
  }

  double get effectiveLightStrength {
    switch (mode) {
      case LiquidGlassQaMode.finalGlass:
      case LiquidGlassQaMode.fresnelOnly:
        return lightStrength;
      case LiquidGlassQaMode.identity:
      case LiquidGlassQaMode.coreOnly:
      case LiquidGlassQaMode.refractionOnly:
      case LiquidGlassQaMode.chromaticOnly:
      case LiquidGlassQaMode.shapeOnly:
        return 0;
    }
  }

  double get effectiveRimStrength {
    switch (mode) {
      case LiquidGlassQaMode.finalGlass:
      case LiquidGlassQaMode.fresnelOnly:
        return rimStrength;
      case LiquidGlassQaMode.identity:
      case LiquidGlassQaMode.coreOnly:
      case LiquidGlassQaMode.refractionOnly:
      case LiquidGlassQaMode.chromaticOnly:
      case LiquidGlassQaMode.shapeOnly:
        return 0;
    }
  }

  bool get isIdentityLike =>
      mode == LiquidGlassQaMode.identity || mode == LiquidGlassQaMode.shapeOnly;

  /// 根据边缘折射与色散计算实际需要的横向 overscan。
  ///
  /// V8 没有中心 magnification，因此 capture 预算只由 edge optical band 决定。
  double overscanXFor(double visibleWidth) {
    final opticalBudget =
        effectiveRefraction.abs() + effectiveChromatic.abs() + 4;
    return math.max(overscanX, opticalBudget);
  }

  double overscanYFor(double visibleHeight) {
    final opticalBudget =
        effectiveRefraction.abs() * math.max(verticalRefractionScale, 0.40) +
            effectiveChromatic.abs() +
            4;
    return math.max(overscanY, opticalBudget);
  }

  double maxSampleOffsetXFor(double visibleWidth) {
    return effectiveRefraction.abs() + effectiveChromatic.abs();
  }

  double maxSampleOffsetYFor(double visibleHeight) {
    return effectiveRefraction.abs() * math.max(verticalRefractionScale, 0.40) +
        effectiveChromatic.abs();
  }

  LiquidGlassTuning copyWith({
    double? lensExponent,
    double? lensWidthScale,
    double? lensHeight,
    double? pressedScale,
    double? overscanX,
    double? overscanY,
    double? refractionHeight,
    double? refraction,
    double? verticalRefractionScale,
    double? refractionBandStart,
    double? refractionBandPeak,
    double? refractionBandEnd,
    double? magnification,
    double? magnificationRadius,
    double? chromatic,
    double? chromaticStart,
    double? rimStrength,
    double? lightStrength,
    double? velocityNormalization,
    double? flowStrength,
    double? dockAlpha,
    double? dockBlur,
    double? dockLensHeight,
    double? dockLensAmount,
    LiquidGlassQaMode? mode,
    LiquidNavColorPreset? colorPreset,
    bool? showCaptureBounds,
  }) {
    return LiquidGlassTuning(
      lensExponent: lensExponent ?? this.lensExponent,
      lensWidthScale: lensWidthScale ?? this.lensWidthScale,
      lensHeight: lensHeight ?? this.lensHeight,
      pressedScale: pressedScale ?? this.pressedScale,
      overscanX: overscanX ?? this.overscanX,
      overscanY: overscanY ?? this.overscanY,
      refractionHeight: refractionHeight ?? this.refractionHeight,
      refraction: refraction ?? this.refraction,
      verticalRefractionScale:
          verticalRefractionScale ?? this.verticalRefractionScale,
      refractionBandStart: refractionBandStart ?? this.refractionBandStart,
      refractionBandPeak: refractionBandPeak ?? this.refractionBandPeak,
      refractionBandEnd: refractionBandEnd ?? this.refractionBandEnd,
      magnification: magnification ?? this.magnification,
      magnificationRadius: magnificationRadius ?? this.magnificationRadius,
      chromatic: chromatic ?? this.chromatic,
      chromaticStart: chromaticStart ?? this.chromaticStart,
      rimStrength: rimStrength ?? this.rimStrength,
      lightStrength: lightStrength ?? this.lightStrength,
      velocityNormalization:
          velocityNormalization ?? this.velocityNormalization,
      flowStrength: flowStrength ?? this.flowStrength,
      dockAlpha: dockAlpha ?? this.dockAlpha,
      dockBlur: dockBlur ?? this.dockBlur,
      dockLensHeight: dockLensHeight ?? this.dockLensHeight,
      dockLensAmount: dockLensAmount ?? this.dockLensAmount,
      mode: mode ?? this.mode,
      colorPreset: colorPreset ?? this.colorPreset,
      showCaptureBounds: showCaptureBounds ?? this.showCaptureBounds,
    );
  }
}

/// 计算导航 item 在 Idle 与连续 Lens 场之间的颜色权重。
double liquidNavFocusWeight({
  required int currentIndex,
  required int index,
  required double visualPosition,
  required double activation,
}) {
  final distance = (visualPosition - index).abs();
  final t = distance.clamp(0.0, 1.0).toDouble();
  final smoothDistance = t * t * (3 - 2 * t);
  final liquidWeight = 1 - smoothDistance;
  final idleWeight = currentIndex == index ? 1.0 : 0.0;
  return ui
      .lerpDouble(
        idleWeight,
        liquidWeight,
        activation.clamp(0.0, 1.0).toDouble(),
      )!
      .clamp(0.0, 1.0);
}

/// `liquid_nav_lens.frag` 的具名 uniform 布局。
///
/// Flutter 的 runtime effect API 只提供按位置写入 float。将布局集中在一处，便于
/// review shader 变更，也避免新增 uniform 后无意中移动后续所有值。
class LiquidGlassShaderUniforms {
  const LiquidGlassShaderUniforms({
    required this.captureSize,
    required this.lensCenter,
    required this.lensSize,
    required this.lensExponent,
    required this.refraction,
    required this.magnification,
    required this.chromatic,
    required this.velocity,
    required this.direction,
    required this.edgeCompression,
    required this.dragState,
    required this.lightStrength,
    required this.rimStrength,
    required this.verticalRefractionScale,
    required this.refractionBandStart,
    required this.refractionBandPeak,
    required this.refractionBandEnd,
    required this.magnificationRadius,
    required this.chromaticStart,
    required this.flowStrength,
    required this.activation,
    required this.pressDepth,
    this.tint = const Color(0x00FFFFFF),
  });

  static const sizeX = 0;
  static const sizeY = 1;
  static const lensCenterX = 2;
  static const lensCenterY = 3;
  static const lensHalfWidth = 4;
  static const lensHalfHeight = 5;
  static const lensExponentIndex = 6;
  static const refractionIndex = 7;
  static const magnificationIndex = 8;
  static const chromaticIndex = 9;
  static const velocityIndex = 10;
  static const directionIndex = 11;
  static const edgeCompressionIndex = 12;
  static const dragStateIndex = 13;
  static const tintR = 14;
  static const tintG = 15;
  static const tintB = 16;
  static const tintA = 17;
  static const lightStrengthIndex = 18;
  static const rimStrengthIndex = 19;
  static const verticalRefractionScaleIndex = 20;
  static const refractionBandStartIndex = 21;
  static const refractionBandPeakIndex = 22;
  static const refractionBandEndIndex = 23;
  static const magnificationRadiusIndex = 24;
  static const chromaticStartIndex = 25;
  static const flowStrengthIndex = 26;
  static const activationIndex = 27;
  static const pressDepthIndex = 28;

  final Size captureSize;
  final Offset lensCenter;
  final Size lensSize;
  final double lensExponent;
  final double refraction;
  final double magnification;
  final double chromatic;
  final double velocity;
  final double direction;
  final double edgeCompression;
  final double dragState;
  final double lightStrength;
  final double rimStrength;
  final double verticalRefractionScale;
  final double refractionBandStart;
  final double refractionBandPeak;
  final double refractionBandEnd;
  final double magnificationRadius;
  final double chromaticStart;
  final double flowStrength;
  final double activation;
  final double pressDepth;
  final Color tint;

  /// Fragment shader 期望收到的精确 float 序列。
  List<double> get values => [
        captureSize.width,
        captureSize.height,
        lensCenter.dx,
        lensCenter.dy,
        lensSize.width * 0.5,
        lensSize.height * 0.5,
        lensExponent,
        refraction,
        magnification,
        chromatic,
        velocity,
        direction,
        edgeCompression,
        dragState,
        tint.r,
        tint.g,
        tint.b,
        tint.a,
        lightStrength,
        rimStrength,
        verticalRefractionScale,
        refractionBandStart,
        refractionBandPeak,
        refractionBandEnd,
        magnificationRadius,
        chromaticStart,
        flowStrength,
        activation,
        pressDepth,
      ];

  void apply(ui.FragmentShader shader) {
    final floats = values;
    for (var index = 0; index < floats.length; index++) {
      shader.setFloat(index, floats[index]);
    }
  }
}
