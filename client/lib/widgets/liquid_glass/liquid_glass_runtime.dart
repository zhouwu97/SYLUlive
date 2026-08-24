import 'package:flutter/foundation.dart';

/// Liquid Glass 的运行时渲染诊断。
///
/// A 表示当前 Lens 使用了 FragmentShader；C 表示已经明确降级到
/// BackdropFilter blur。B 保留给未来的中间实现，不把“尚未探测完成”误报
/// 成任何一个真实渲染等级。
enum LiquidGlassTier { unknown, a, b, c }

enum LiquidGlassQaMode { finalGlass, identity, refractionOnly, shapeOnly }

/// QA 页面可调整的光学参数。默认值就是线上底栏的基线，避免调试入口
/// 改变正常页面的参数来源。
class LiquidGlassTuning {
  const LiquidGlassTuning({
    this.refraction = 9.0,
    this.magnification = 1.035,
    this.chromatic = 0.6,
    this.rimStrength = 0.08,
    this.lightStrength = 0.18,
    this.dockAlpha = 1.0,
    this.dockBlur = 4.5,
    this.mode = LiquidGlassQaMode.finalGlass,
  });

  final double refraction;
  final double magnification;
  final double chromatic;
  final double rimStrength;
  final double lightStrength;
  final double dockAlpha;
  final double dockBlur;
  final LiquidGlassQaMode mode;

  double get effectiveRefraction {
    return mode == LiquidGlassQaMode.finalGlass ||
            mode == LiquidGlassQaMode.refractionOnly
        ? refraction
        : 0;
  }

  double get effectiveMagnification {
    return mode == LiquidGlassQaMode.finalGlass ? magnification : 1;
  }

  double get effectiveChromatic {
    return mode == LiquidGlassQaMode.finalGlass ? chromatic : 0;
  }

  double get effectiveRimStrength {
    return mode == LiquidGlassQaMode.finalGlass ? rimStrength : 0;
  }

  double get effectiveLightStrength {
    return mode == LiquidGlassQaMode.finalGlass ? lightStrength : 0;
  }

  bool get isIdentityLike =>
      mode == LiquidGlassQaMode.identity || mode == LiquidGlassQaMode.shapeOnly;

  LiquidGlassTuning copyWith({
    double? refraction,
    double? magnification,
    double? chromatic,
    double? rimStrength,
    double? lightStrength,
    double? dockAlpha,
    double? dockBlur,
    LiquidGlassQaMode? mode,
  }) {
    return LiquidGlassTuning(
      refraction: refraction ?? this.refraction,
      magnification: magnification ?? this.magnification,
      chromatic: chromatic ?? this.chromatic,
      rimStrength: rimStrength ?? this.rimStrength,
      lightStrength: lightStrength ?? this.lightStrength,
      dockAlpha: dockAlpha ?? this.dockAlpha,
      dockBlur: dockBlur ?? this.dockBlur,
      mode: mode ?? this.mode,
    );
  }
}

class LiquidGlassRuntimeStatus {
  const LiquidGlassRuntimeStatus({
    this.tier = LiquidGlassTier.unknown,
    this.shaderSupported = false,
    this.detail = '',
  });

  final LiquidGlassTier tier;
  final bool shaderSupported;
  final String detail;

  String get tierLabel {
    switch (tier) {
      case LiquidGlassTier.unknown:
        return '?';
      case LiquidGlassTier.a:
        return 'A';
      case LiquidGlassTier.b:
        return 'B';
      case LiquidGlassTier.c:
        return 'C';
    }
  }
}

/// 仅供底栏诊断浮层和开发测试读取，不参与业务导航状态。
final liquidGlassRuntimeStatus = ValueNotifier<LiquidGlassRuntimeStatus>(
  const LiquidGlassRuntimeStatus(),
);

void updateLiquidGlassRuntimeStatus({
  required LiquidGlassTier tier,
  required bool shaderSupported,
  String detail = '',
}) {
  final nextStatus = LiquidGlassRuntimeStatus(
    tier: tier,
    shaderSupported: shaderSupported,
    detail: detail,
  );
  // Shader 探测可能从 Lens 的 initState 触发，而此时仍处在首帧 build/layout
  // 中；把全局诊断通知推迟到当前 frame 后，避免 Overlay 在 build 中 setState。
  Future<void>.microtask(() {
    if (liquidGlassRuntimeStatus.value.tier == nextStatus.tier &&
        liquidGlassRuntimeStatus.value.shaderSupported ==
            nextStatus.shaderSupported &&
        liquidGlassRuntimeStatus.value.detail == nextStatus.detail) {
      return;
    }
    liquidGlassRuntimeStatus.value = nextStatus;
  });
}
