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

/// Liquid Glass 的视觉实现档案。
///
/// `current` 是 MCP HEAD 的生产路径；`oldV1` 只供 QA 页面复现
/// 57ca812 的首版液态底栏，不改变生产默认值或交互状态机。
enum LiquidGlassVisualProfile {
  current,
  oldV1,
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
    this.refractionHeight = 12.0,
    this.refraction = 14.0,
    this.verticalRefractionScale = 1.0,
    // 保留字段以兼容 QA 配置文件；V8 shader 不再使用中心放大。
    this.magnification = 1.0,
    this.magnificationRadius = 0.66,
    this.chromatic = 1.0,
    this.rimStrength = 0.16,
    this.lightStrength = 0.30,
    this.velocityNormalization = 1000.0,
    this.flowStrength = 0.72,
    // Dock 降低白色覆盖，保留背景层次给 shader 折射；这不是减少动效，
    // 而是把“玻璃”从厚重磨砂恢复成有透光和重量的材质。
    this.dockAlpha = 0.16,
    this.dockBlur = 8.0,
    this.dockLensHeight = 24.0,
    this.dockLensAmount = 24.0,
    // Dock 对齐 Kyant：整块 Dock 静止时就有 blur(8) + lens(24, 24)。
    this.idleOpticalActivation = 0.0,
    this.dockRefraction = 24.0,
    this.dockChromatic = 0.0,
    this.dockRefractionHeight = 24.0,
    this.dockSaturation = 1.04,
    this.dockContrast = 1.01,
    this.dockSpecularStrength = 1.0,
    this.dockRecoilDistance = 3.5,
    this.dockRecoilStrength = 0.82,
    this.lensSurfaceAlpha = 0.12,
    this.lensPressedSurfaceAlpha = 0.05,
    this.highlightStrength = 1.0,
    this.highlightRadius = 1.5,
    this.mode = LiquidGlassQaMode.finalGlass,
    this.colorPreset = LiquidNavColorPreset.sylulive,
    this.visualProfile = LiquidGlassVisualProfile.current,
    this.showCaptureBounds = false,
  });

  /// MCP HEAD 的当前视觉档案，显式命名以便 QA 做 A/B 对照。
  static const current = LiquidGlassTuning();

  /// 克制的材质预设，用于在弱光学畸变下对比几何轮廓。
  static const natural = LiquidGlassTuning(
    refractionHeight: 12.0,
    refraction: 14.0,
    chromatic: 1.0,
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

  /// 57ca812（2026-08-24 09:13）的首版液态玻璃视觉档案。
  ///
  /// 旧版使用较宽的稳定 Capsule、Dock 16px blur、白色/青白渐变 surface，
  /// 并由独立 shader 负责中心 zoom、边缘折射、轻色散和左上高光。
  /// 它只在 Liquid Glass QA 页面用于 A/B，不作为默认生产 preset。
  static const oldV1 = LiquidGlassTuning(
    lensHeight: 58.0,
    pressedScale: 1.0,
    overscanX: 0.0,
    overscanY: 0.0,
    refractionHeight: 1.0,
    refraction: 8.0,
    verticalRefractionScale: 1.0,
    magnification: 0.85,
    magnificationRadius: 0.66,
    chromatic: 0.075,
    dockAlpha: 0.62,
    dockBlur: 16.0,
    dockLensHeight: 0.0,
    dockLensAmount: 0.0,
    idleOpticalActivation: 1.0,
    dockRefraction: 0.0,
    dockChromatic: 0.0,
    dockRefractionHeight: 0.0,
    dockSaturation: 1.0,
    dockContrast: 1.0,
    dockSpecularStrength: 0.0,
    dockRecoilDistance: 0.0,
    dockRecoilStrength: 0.0,
    lensSurfaceAlpha: 0.0,
    lensPressedSurfaceAlpha: 0.0,
    highlightStrength: 1.0,
    highlightRadius: 1.0,
    visualProfile: LiquidGlassVisualProfile.oldV1,
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

  final double magnification;
  final double magnificationRadius;

  final double chromatic;

  final double rimStrength;
  final double lightStrength;
  final double velocityNormalization;
  final double flowStrength;

  final double dockAlpha;
  final double dockBlur;
  final double dockLensHeight;
  final double dockLensAmount;

  /// Idle 默认关闭光学激活，保持 frosted blur；按压、拖拽与切换阶段逐段
  /// 提升折射与色散，而不是在 phase 之间切换成另一颗静态 indicator。
  final double idleOpticalActivation;

  /// Dock 的独立光学参数。Selection 与 Dock 共用 shader 思路，但不共用
  /// 强度，避免整块底栏变成放大的鱼眼滤镜。
  final double dockRefraction;
  final double dockChromatic;
  final double dockRefractionHeight;
  final double dockSaturation;
  final double dockContrast;
  final double dockSpecularStrength;
  final double dockRecoilDistance;
  final double dockRecoilStrength;

  final double lensSurfaceAlpha;
  final double lensPressedSurfaceAlpha;
  final double highlightStrength;
  final double highlightRadius;
  final LiquidGlassQaMode mode;
  final LiquidNavColorPreset colorPreset;
  final LiquidGlassVisualProfile visualProfile;
  final bool showCaptureBounds;

  bool get isOldV1 => visualProfile == LiquidGlassVisualProfile.oldV1;

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
    double? magnification,
    double? magnificationRadius,
    double? chromatic,
    double? rimStrength,
    double? lightStrength,
    double? velocityNormalization,
    double? flowStrength,
    double? dockAlpha,
    double? dockBlur,
    double? dockLensHeight,
    double? dockLensAmount,
    double? idleOpticalActivation,
    double? dockRefraction,
    double? dockChromatic,
    double? dockRefractionHeight,
    double? dockSaturation,
    double? dockContrast,
    double? dockSpecularStrength,
    double? dockRecoilDistance,
    double? dockRecoilStrength,
    double? lensSurfaceAlpha,
    double? lensPressedSurfaceAlpha,
    double? highlightStrength,
    double? highlightRadius,
    LiquidGlassQaMode? mode,
    LiquidNavColorPreset? colorPreset,
    LiquidGlassVisualProfile? visualProfile,
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
      magnification: magnification ?? this.magnification,
      magnificationRadius: magnificationRadius ?? this.magnificationRadius,
      chromatic: chromatic ?? this.chromatic,
      rimStrength: rimStrength ?? this.rimStrength,
      lightStrength: lightStrength ?? this.lightStrength,
      velocityNormalization:
          velocityNormalization ?? this.velocityNormalization,
      flowStrength: flowStrength ?? this.flowStrength,
      dockAlpha: dockAlpha ?? this.dockAlpha,
      dockBlur: dockBlur ?? this.dockBlur,
      dockLensHeight: dockLensHeight ?? this.dockLensHeight,
      dockLensAmount: dockLensAmount ?? this.dockLensAmount,
      idleOpticalActivation:
          idleOpticalActivation ?? this.idleOpticalActivation,
      dockRefraction: dockRefraction ?? this.dockRefraction,
      dockChromatic: dockChromatic ?? this.dockChromatic,
      dockRefractionHeight: dockRefractionHeight ?? this.dockRefractionHeight,
      dockSaturation: dockSaturation ?? this.dockSaturation,
      dockContrast: dockContrast ?? this.dockContrast,
      dockSpecularStrength: dockSpecularStrength ?? this.dockSpecularStrength,
      dockRecoilDistance: dockRecoilDistance ?? this.dockRecoilDistance,
      dockRecoilStrength: dockRecoilStrength ?? this.dockRecoilStrength,
      lensSurfaceAlpha: lensSurfaceAlpha ?? this.lensSurfaceAlpha,
      lensPressedSurfaceAlpha:
          lensPressedSurfaceAlpha ?? this.lensPressedSurfaceAlpha,
      highlightStrength: highlightStrength ?? this.highlightStrength,
      highlightRadius: highlightRadius ?? this.highlightRadius,
      mode: mode ?? this.mode,
      colorPreset: colorPreset ?? this.colorPreset,
      visualProfile: visualProfile ?? this.visualProfile,
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
/// ImageFilter.shader 会由引擎写入前两个 float（输入纹理宽高）。应用从 index 2
/// 开始写入逻辑坐标契约，shader 再根据真实纹理尺寸统一换算 DPR，避免部分参数是
/// logical px、部分参数是 texture px 所造成的折射错位和彩色条带。
class LiquidGlassShaderUniforms {
  const LiquidGlassShaderUniforms({
    required this.captureSize,
    required this.lensCenter,
    required this.lensSize,
    required this.refractionHeight,
    required this.refraction,
    required this.chromatic,
    required this.activation,
  });

  static const engineOwnedValueCount = 2;
  static const engineInputWidth = 0;
  static const engineInputHeight = 1;
  static const customUniformStart = engineOwnedValueCount;
  static const logicalSizeX = 2;
  static const logicalSizeY = 3;
  static const lensCenterX = 4;
  static const lensCenterY = 5;
  static const lensHalfWidth = 6;
  static const lensHalfHeight = 7;
  static const refractionHeightIndex = 8;
  static const refractionIndex = 9;
  static const chromaticIndex = 10;
  static const activationIndex = 11;

  final Size captureSize;
  final Offset lensCenter;
  final Size lensSize;
  final double refractionHeight;
  final double refraction;
  final double chromatic;
  final double activation;

  /// 完整 uniform 布局。前两项是引擎拥有的占位符，应用不得写入。
  List<double> get values => [
        double.nan,
        double.nan,
        captureSize.width,
        captureSize.height,
        lensCenter.dx,
        lensCenter.dy,
        lensSize.width * 0.5,
        lensSize.height * 0.5,
        refractionHeight,
        -refraction,
        chromatic,
        activation,
      ];

  void apply(ui.FragmentShader shader) {
    final floats = values;
    for (var index = customUniformStart; index < floats.length; index++) {
      shader.setFloat(index, floats[index]);
    }
  }
}

/// `liquid_nav_lens_v1.frag` 的具名 uniform 布局。
///
/// 57ca812 的 shader 使用屏幕归一化的 Capsule 中心/半尺寸，并保留了
/// `uTint`、`uZoom`、`uMotion` 与 `uDirection` 这组首版光学参数。
class LiquidGlassOldV1ShaderUniforms {
  const LiquidGlassOldV1ShaderUniforms({
    required this.center,
    required this.halfSize,
    required this.refraction,
    required this.zoom,
    required this.chromatic,
    required this.motion,
    required this.direction,
    required this.tint,
  });

  static const engineOwnedValueCount = 2;
  static const customUniformStart = engineOwnedValueCount;
  static const centerX = 2;
  static const centerY = 3;
  static const halfWidth = 4;
  static const halfHeight = 5;
  static const refractionIndex = 6;
  static const zoomIndex = 8;
  static const chromaticIndex = 7;
  static const motionIndex = 9;
  static const directionIndex = 10;
  static const tintR = 11;
  static const tintG = 12;
  static const tintB = 13;
  static const tintA = 14;

  final Offset center;
  final Size halfSize;
  final double refraction;
  final double zoom;
  final double chromatic;
  final double motion;
  final double direction;
  final Color tint;

  List<double> get values => [
        double.nan,
        double.nan,
        center.dx,
        center.dy,
        halfSize.width,
        halfSize.height,
        refraction,
        chromatic,
        zoom,
        motion,
        direction,
        tint.r,
        tint.g,
        tint.b,
        tint.a,
      ];

  void apply(ui.FragmentShader shader) {
    final floats = values;
    for (var index = customUniformStart; index < floats.length; index++) {
      shader.setFloat(index, floats[index]);
    }
  }
}

/// `liquid_nav_dock.frag` 的轻量三通道 uniform 布局。
class LiquidGlassDockShaderUniforms {
  const LiquidGlassDockShaderUniforms({
    required this.logicalSize,
    required this.dockSize,
    required this.refraction,
    required this.chromatic,
    required this.refractionHeight,
    required this.activation,
  });

  static const engineOwnedValueCount = 2;
  static const customUniformStart = engineOwnedValueCount;
  static const logicalSizeX = 2;
  static const logicalSizeY = 3;
  static const dockSizeX = 4;
  static const dockSizeY = 5;
  static const refractionIndex = 6;
  static const chromaticIndex = 7;
  static const refractionHeightIndex = 8;
  static const activationIndex = 9;

  final Size logicalSize;
  final Size dockSize;
  final double refraction;
  final double chromatic;
  final double refractionHeight;
  final double activation;

  List<double> get values => [
        double.nan,
        double.nan,
        logicalSize.width,
        logicalSize.height,
        dockSize.width,
        dockSize.height,
        -refraction,
        chromatic,
        refractionHeight,
        activation,
      ];

  void apply(ui.FragmentShader shader) {
    final floats = values;
    for (var index = customUniformStart; index < floats.length; index++) {
      shader.setFloat(index, floats[index]);
    }
  }
}
