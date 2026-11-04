import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';

/// 玻璃底面与前景分别过渡，背景滤镜始终留在透明度离屏层之外。
class AppSurfaceTransition extends InheritedWidget {
  const AppSurfaceTransition({
    super.key,
    required this.progress,
    required super.child,
  });

  final double progress;

  static double progressOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppSurfaceTransition>()
          ?.progress ??
      1;

  static bool filtersEnabledOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_SurfaceForeground>()
          ?.filtersEnabled ??
      true;

  /// 内层表面由最外层前景统一淡入；过渡期间不在该离屏层内采样背景。
  static Widget foreground(BuildContext context,
          {required double progress, required Widget? child}) =>
      AppSurfaceTransition(
        progress: 1,
        child: _SurfaceForeground(
          filtersEnabled: filtersEnabledOf(context) && progress == 1,
          child: Opacity(opacity: progress, child: child),
        ),
      );

  @override
  bool updateShouldNotify(AppSurfaceTransition oldWidget) =>
      progress != oldWidget.progress;
}

class _SurfaceForeground extends InheritedWidget {
  const _SurfaceForeground(
      {required this.filtersEnabled, required super.child});

  final bool filtersEnabled;

  @override
  bool updateShouldNotify(_SurfaceForeground oldWidget) =>
      filtersEnabled != oldWidget.filtersEnabled;
}

/// 普通材质保留原淡入；玻璃材质把进度交给原有卡片底面及前景。
class AppSurfaceFadeTransition extends StatelessWidget {
  const AppSurfaceFadeTransition({
    super.key,
    required this.opacity,
    required this.child,
  });

  final Animation<double> opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeProvider?>();
    final glass =
        settings?.frostedGlass == true && settings!.shouldShowCustomBackground;
    return AnimatedBuilder(
      animation: opacity,
      child: child,
      builder: (context, child) => AppSurfaceTransition(
        progress: glass ? opacity.value.clamp(0, 1) : 1,
        child: Opacity(
            opacity: glass ? 1 : opacity.value.clamp(0, 1), child: child),
      ),
    );
  }
}

class AppSurfaceOpacity extends StatelessWidget {
  const AppSurfaceOpacity({
    super.key,
    required this.opacity,
    required this.child,
  });

  final double opacity;
  final Widget child;

  @override
  Widget build(BuildContext context) => AppSurfaceFadeTransition(
        opacity: AlwaysStoppedAnimation(opacity),
        child: child,
      );
}

class AppSurfaceAnimatedOpacity extends ImplicitlyAnimatedWidget {
  const AppSurfaceAnimatedOpacity({
    super.key,
    required this.opacity,
    required this.child,
    required super.duration,
    super.curve,
    super.onEnd,
  }) : assert(opacity >= 0 && opacity <= 1);

  final double opacity;
  final Widget child;

  @override
  AnimatedWidgetBaseState<AppSurfaceAnimatedOpacity> createState() =>
      _AppSurfaceAnimatedOpacityState();
}

class _AppSurfaceAnimatedOpacityState
    extends AnimatedWidgetBaseState<AppSurfaceAnimatedOpacity> {
  Tween<double>? _opacity;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _opacity = visitor(_opacity, widget.opacity,
        (value) => Tween<double>(begin: value as double)) as Tween<double>?;
  }

  @override
  Widget build(BuildContext context) => AppSurfaceFadeTransition(
        opacity: _opacity!.animate(animation),
        child: widget.child,
      );
}
