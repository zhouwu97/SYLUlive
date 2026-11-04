import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../theme/app_radius.dart';
import '../theme/app_motion.dart';
import 'app_card.dart';
import 'app_surface_transition.dart';

/// 毛玻璃弹窗的底面、内容和模糊分别过渡，避免整窗 FadeTransition 的黑块。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
  AnimationStyle? animationStyle,
}) {
  final settings = context.read<ThemeProvider?>();
  if (settings?.frostedGlass != true || !settings!.shouldShowCustomBackground) {
    return showDialog<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
      barrierLabel: barrierLabel,
      useSafeArea: useSafeArea,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      anchorPoint: anchorPoint,
      traversalEdgeBehavior: traversalEdgeBehavior,
      fullscreenDialog: fullscreenDialog,
      requestFocus: requestFocus,
      animationStyle: animationStyle,
    );
  }
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  return navigator.push<T>(_AppDialogRoute<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    barrierColor:
        barrierColor ?? DialogTheme.of(context).barrierColor ?? Colors.black54,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    settings: routeSettings,
    anchorPoint: anchorPoint,
    traversalEdgeBehavior:
        traversalEdgeBehavior ?? TraversalEdgeBehavior.closedLoop,
    fullscreenDialog: fullscreenDialog,
    requestFocus: requestFocus,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    animationStyle: animationStyle ??
        AnimationStyle(
          duration: AppMotion.duration(context, AppMotion.overlay),
        ),
    reverseDuration: animationStyle?.reverseDuration ??
        AppMotion.duration(context, AppMotion.fast),
    curve: animationStyle?.curve ?? AppMotion.standard,
    reverseCurve: animationStyle?.reverseCurve ?? AppMotion.outgoing,
  ));
}

class _AppDialogRoute<T> extends DialogRoute<T> {
  _AppDialogRoute({
    required super.context,
    required super.builder,
    required super.barrierDismissible,
    required super.barrierColor,
    required super.themes,
    required super.animationStyle,
    required super.barrierLabel,
    required super.useSafeArea,
    required super.settings,
    required super.anchorPoint,
    required super.traversalEdgeBehavior,
    required super.fullscreenDialog,
    required super.requestFocus,
    required this.reverseDuration,
    required this.curve,
    required this.reverseCurve,
  });

  final Duration reverseDuration;
  final Curve curve;
  final Curve reverseCurve;

  @override
  Duration get reverseTransitionDuration => reverseDuration;

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final progress =
            (animation.status == AnimationStatus.reverse ? reverseCurve : curve)
                .transform(animation.value)
                .clamp(0.0, 1.0);
        final settings = context.watch<ThemeProvider?>();
        final glass = settings?.frostedGlass == true &&
            settings!.shouldShowCustomBackground;
        final content = AppSurfaceTransition(
          progress: glass ? progress : 1,
          child: Opacity(opacity: glass ? 1 : progress, child: child),
        );
        return Transform.scale(
          scale: AppMotion.reducedMotion(context) ? 1 : 0.96 + 0.04 * progress,
          child: content,
        );
      },
    );
  }
}

/// 保留系统 Dialog 的布局、安全区、键盘避让与语义，只替换弹窗表面。
class AppDialog extends Dialog {
  const AppDialog({
    super.key,
    super.backgroundColor,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.insetAnimationDuration,
    super.insetAnimationCurve,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.alignment,
    super.child,
    super.semanticsRole,
    super.constraints,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ThemeProvider?>();
    final glass = settings?.frostedGlass == true;
    final theme = DialogTheme.of(context);
    final dialogShape = shape ??
        theme.shape ??
        const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg)));
    final glassShape = glass && dialogShape is OutlinedBorder
        ? dialogShape.copyWith(side: BorderSide.none)
        : dialogShape;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      insetAnimationDuration: insetAnimationDuration,
      insetAnimationCurve: insetAnimationCurve,
      insetPadding: insetPadding,
      clipBehavior: Clip.none,
      shape: glassShape,
      alignment: alignment,
      constraints: constraints,
      semanticsRole: semanticsRole,
      child: AppCardMaterial(
        surfaceOpacity: glass
            ? (settings!.shouldShowCustomBackground
                ? settings.componentOpacity
                : 1)
            : 1,
        elevation: glass ? 0 : elevation ?? theme.elevation ?? 6,
        shadowColor: shadowColor ?? theme.shadowColor,
        surfaceTintColor: glass
            ? Colors.transparent
            : surfaceTintColor ?? theme.surfaceTintColor,
        color: backgroundColor ??
            theme.backgroundColor ??
            Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: glassShape,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

/// 复用 Flutter AlertDialog 的内容测量与按钮排版，不复制其布局实现。
class AppAlertDialog extends AlertDialog {
  const AppAlertDialog({
    super.key,
    super.icon,
    super.iconPadding,
    super.iconColor,
    super.title,
    super.titlePadding,
    super.titleTextStyle,
    super.content,
    super.contentPadding,
    super.contentTextStyle,
    super.actions,
    super.actionsPadding,
    super.actionsAlignment,
    super.actionsOverflowAlignment,
    super.actionsOverflowDirection,
    super.actionsOverflowButtonSpacing,
    super.buttonPadding,
    super.backgroundColor,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.semanticLabel,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.alignment,
    super.scrollable,
    super.constraints,
  });

  @override
  Widget build(BuildContext context) {
    final built = super.build(context);
    if (built is! Dialog) {
      return built;
    }
    return AppDialog(
      backgroundColor: built.backgroundColor,
      elevation: built.elevation,
      shadowColor: built.shadowColor,
      surfaceTintColor: built.surfaceTintColor,
      insetPadding: built.insetPadding,
      clipBehavior: built.clipBehavior,
      shape: built.shape,
      alignment: built.alignment,
      constraints: built.constraints,
      semanticsRole: built.semanticsRole,
      child: built.child,
    );
  }
}
