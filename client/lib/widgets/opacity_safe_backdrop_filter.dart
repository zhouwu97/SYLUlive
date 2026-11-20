import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_surface_transition.dart';

/// 原生淡入保留系统动效；滤镜不采样其透明离屏层，结束后恢复背景采样。
/// 不读取材质偏好，毛玻璃与液态底栏继续各自控制启用及模糊强度。
class OpacitySafeBackdropFilter extends StatelessWidget {
  const OpacitySafeBackdropFilter({
    super.key,
    required this.filter,
    required this.child,
    this.enabled = true,
    this.blendMode = BlendMode.srcOver,
    this.grouped = false,
  });

  final ui.ImageFilter filter;
  final Widget? child;
  final bool enabled;
  final BlendMode blendMode;

  /// 加入最近的 [BackdropGroup]，同组滤镜共用一次背景采样。只用于互不重叠、
  /// 直接压在页面背景上的卡片；底栏、弹层要模糊自己下面的内容，不能分组。
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final filtersEnabled = AppSurfaceTransition.filtersEnabledOf(context);
    final fades = <Animation<double>>[];
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is FadeTransition) fades.add(widget.opacity);
      if (widget is SliverFadeTransition) fades.add(widget.opacity);
      return true;
    });
    return AnimatedBuilder(
      animation: Listenable.merge(fades),
      child: child,
      builder: (context, child) => BackdropFilter(
        enabled:
            enabled && filtersEnabled && !fades.any((fade) => fade.value < 1),
        filter: filter,
        blendMode: blendMode,
        backdropGroupKey:
            grouped ? BackdropGroup.of(context)?.backdropKey : null,
        child: child,
      ),
    );
  }
}
