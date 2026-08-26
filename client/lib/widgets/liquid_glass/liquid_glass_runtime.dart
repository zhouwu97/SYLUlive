import 'package:flutter/foundation.dart';

export 'liquid_glass_tuning.dart';

/// Liquid Glass 的运行时渲染诊断。
///
/// A 表示当前 Lens 使用了 FragmentShader；C 表示已经明确降级到
/// BackdropFilter blur。B 保留给未来的中间实现，不把“尚未探测完成”误报成
/// 任何一个真实渲染等级。
enum LiquidGlassTier { unknown, a, b, c }

class LiquidGlassRuntimeStatus {
  const LiquidGlassRuntimeStatus({
    this.tier = LiquidGlassTier.unknown,
    this.shaderSupported = false,
    this.shaderEnabled = false,
    this.detail = '',
  });

  final LiquidGlassTier tier;
  final bool shaderSupported;
  final bool shaderEnabled;
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

// 一旦关键 shader 明确失败，本次进程内不允许后续另一个 shader 的成功
// 加载把整体 Tier 伪装回 A。Lens 与 Dock 是并行加载的，必须保留最差结果。
bool _hasCriticalShaderFallback = false;
String _criticalShaderFallbackDetail = '';
bool _criticalShaderSupported = false;

void updateLiquidGlassRuntimeStatus({
  required LiquidGlassTier tier,
  required bool shaderSupported,
  bool shaderEnabled = true,
  String detail = '',
}) {
  if (tier == LiquidGlassTier.c) {
    _hasCriticalShaderFallback = true;
    _criticalShaderFallbackDetail = detail;
    _criticalShaderSupported = shaderSupported;
  }
  final hasStickyFallback = _hasCriticalShaderFallback;
  final nextStatus = LiquidGlassRuntimeStatus(
    tier: hasStickyFallback && tier != LiquidGlassTier.c
        ? LiquidGlassTier.c
        : tier,
    shaderSupported: hasStickyFallback && tier != LiquidGlassTier.c
        ? _criticalShaderSupported
        : shaderSupported,
    shaderEnabled: shaderEnabled,
    detail: hasStickyFallback && tier != LiquidGlassTier.c
        ? _criticalShaderFallbackDetail
        : detail,
  );
  // Shader 探测可能从 Lens 的 initState 触发，而此时仍处在首帧 build/layout
  // 中；把全局诊断通知推迟到当前 frame 后，避免 Overlay 在 build 中 setState。
  Future<void>.microtask(() {
    if (liquidGlassRuntimeStatus.value.tier == nextStatus.tier &&
        liquidGlassRuntimeStatus.value.shaderSupported ==
            nextStatus.shaderSupported &&
        liquidGlassRuntimeStatus.value.shaderEnabled ==
            nextStatus.shaderEnabled &&
        liquidGlassRuntimeStatus.value.detail == nextStatus.detail) {
      return;
    }
    liquidGlassRuntimeStatus.value = nextStatus;
  });
}
