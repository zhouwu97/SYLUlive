import 'package:flutter/material.dart';

/// 自定义页面转场路由：右滑推入 + 淡入淡出
/// 支持预测性返回手势预览（Android 14+）
class SlideFadeRoute<T> extends PageRouteBuilder<T> {
  final WidgetBuilder builder;
  final Duration duration;

  SlideFadeRoute({
    required this.builder,
    this.duration = const Duration(milliseconds: 320),
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          allowSnapshotting: true,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            // 预测性返回：secondaryAnimation 驱动前一页面的预览动画
            return _SlideFadeTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            );
          },
        );
}

/// 共享元素 + 滑入转场（用于从列表到详情的过渡）
class SharedSlideRoute<T> extends PageRouteBuilder<T> {
  final WidgetBuilder builder;
  final Duration duration;

  SharedSlideRoute({
    required this.builder,
    this.duration = const Duration(milliseconds: 360),
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          allowSnapshotting: true,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return _SlideFadeTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            );
          },
        );
}

class _SlideFadeTransition extends StatelessWidget {
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  const _SlideFadeTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // animation: 推进 0→1，返回（含预测性手势）1→0
    // secondaryAnimation: 由 Navigator 内部驱动前一页快照的渲染，这里不需要操作
    // Navigator 会在手势返回时自动渲染前一页在下方，当前页滑出即可
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.3, 0), // 从右侧 30% 处滑入
        end: Offset.zero,
      ).animate(CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      )),
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: const Interval(0.0, 0.5, curve: Curves.easeOut),
        ),
        child: child,
      ),
    );
  }
}

/// 底部弹出路由（用于模态弹窗）
class BottomSheetRoute<T> extends PageRouteBuilder<T> {
  final WidgetBuilder builder;

  BottomSheetRoute({
    required this.builder,
  }) : super(
          transitionDuration: const Duration(milliseconds: 300),
          reverseTransitionDuration: const Duration(milliseconds: 250),
          opaque: false,
          allowSnapshotting: false,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                ),
              ),
              child: child,
            );
          },
        );
}

/// 全局过渡构建器
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      return const CupertinoPageTransitionsBuilder().buildTransitions(
          route, context, animation, secondaryAnimation, child);
    }
    return child;
  }
}
