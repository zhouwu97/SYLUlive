import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../theme/app_radius.dart';
import 'app_card.dart';

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
    if (context.watch<ThemeProvider?>()?.frostedGlass != true) {
      return super.build(context);
    }
    final theme = DialogTheme.of(context);
    final dialogShape = shape ??
        theme.shape ??
        const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg)));
    final glassShape = dialogShape is OutlinedBorder
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
    if (context.watch<ThemeProvider?>()?.frostedGlass != true ||
        built is! Dialog) {
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
