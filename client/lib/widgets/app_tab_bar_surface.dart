import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import 'app_card.dart';

/// 筛选栏自身采样壁纸，并把点击状态层限制在栏内，避免绿色 Ink 泄漏到页面。
class AppTabBarSurface extends StatelessWidget implements PreferredSizeWidget {
  const AppTabBarSurface({
    super.key,
    required this.child,
    this.height,
    this.width,
    this.margin,
    this.padding,
    this.decoration,
    this.alignment,
  });

  final TabBar child;
  final double? height;
  final double? width;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final BoxDecoration? decoration;
  final AlignmentGeometry? alignment;

  @override
  Size get preferredSize =>
      Size.fromHeight(height ?? child.preferredSize.height);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = context.watch<ThemeProvider?>()?.frostedGlass == true;
    final radius = decoration?.borderRadius ?? BorderRadius.zero;
    final neutral =
        theme.brightness == Brightness.dark ? Colors.white : Colors.black;
    return AppCardSurface(
      height: preferredSize.height,
      width: width,
      margin: margin,
      padding: padding,
      alignment: alignment,
      decoration: decoration ??
          BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.zero,
          ),
      child: Theme(
        data: theme.copyWith(
            tabBarTheme: theme.tabBarTheme.copyWith(
          dividerColor:
              glass ? Colors.transparent : theme.tabBarTheme.dividerColor,
          overlayColor: WidgetStateProperty.resolveWith((states) => states.any({
                WidgetState.pressed,
                WidgetState.hovered,
                WidgetState.focused
              }.contains)
                  ? neutral.withValues(alpha: .06)
                  : Colors.transparent),
        )),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ),
    );
  }
}
