import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import 'app_card.dart';
import 'frosted_glass.dart';

/// 默认系统底部弹层沿用卡片材质，保留路由、拖动手柄和键盘处理。
/// 自绘透明弹层继续由自己的 AppCardSurface 提供材质。
Future<T?> showAppModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  String? barrierLabel,
  double? elevation,
  ShapeBorder? shape,
  Clip? clipBehavior,
  BoxConstraints? constraints,
  Color? barrierColor,
  bool isScrollControlled = false,
  double scrollControlDisabledMaxHeightRatio = 9 / 16,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  bool useSafeArea = false,
  RouteSettings? routeSettings,
  AnimationController? transitionAnimationController,
  Offset? anchorPoint,
  AnimationStyle? sheetAnimationStyle,
  bool? requestFocus,
}) {
  final appearance = context.read<ThemeProvider?>();
  final glass =
      appearance?.frostedGlass == true && backgroundColor != Colors.transparent;
  final theme = Theme.of(context);
  final sheetTheme = theme.bottomSheetTheme;
  final surface = backgroundColor ??
      sheetTheme.modalBackgroundColor ??
      sheetTheme.backgroundColor ??
      (theme.useMaterial3
          ? theme.colorScheme.surfaceContainerLow
          : theme.canvasColor);
  return showModalBottomSheet<T>(
    context: context,
    builder: glass
        ? (context) => FrostedGlass(enabled: true, child: builder(context))
        : builder,
    backgroundColor: glass
        ? appGlassSurfaceColor(
            context,
            surface,
            appearance!.shouldShowCustomBackground
                ? appearance.componentOpacity
                : 1)
        : backgroundColor,
    barrierLabel: barrierLabel,
    elevation: glass ? 0 : elevation,
    shape: shape,
    clipBehavior: glass ? Clip.antiAlias : clipBehavior,
    constraints: constraints,
    barrierColor: barrierColor,
    isScrollControlled: isScrollControlled,
    scrollControlDisabledMaxHeightRatio: scrollControlDisabledMaxHeightRatio,
    useRootNavigator: useRootNavigator,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: showDragHandle,
    useSafeArea: useSafeArea,
    routeSettings: routeSettings,
    transitionAnimationController: transitionAnimationController,
    anchorPoint: anchorPoint,
    sheetAnimationStyle: sheetAnimationStyle,
    requestFocus: requestFocus,
  );
}
