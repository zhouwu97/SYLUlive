import 'package:flutter/foundation.dart';

/// Liquid Glass 的运行时渲染诊断。
///
/// A 表示已捕获真实背景并通过 GPU 合成；C 表示缺少背景或 shader，
/// 正使用基本可访问导航。B 保留兼容；unknown 表示尚未完成初始化。
enum LiquidGlassTier { unknown, a, b, c }

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
