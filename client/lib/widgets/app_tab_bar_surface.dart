import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
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
  }) : _rounded = false;

  /// 独立顶部标签栏共用圆角与留白，支持 AppBar.bottom 和页面内容区。
  const AppTabBarSurface.rounded({
    super.key,
    required this.child,
    this.height,
    this.width,
    this.padding,
    this.alignment,
  })  : margin = const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration = null,
        _rounded = true;

  final TabBar child;
  final double? height;
  final double? width;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final BoxDecoration? decoration;
  final AlignmentGeometry? alignment;
  final bool _rounded;

  double get _surfaceHeight => height ?? child.preferredSize.height;

  // AppBar 必须同时预留上下留白，避免圆角栏挤进标题区或被裁切。
  @override
  Size get preferredSize =>
      Size.fromHeight(_surfaceHeight + (margin?.vertical ?? 0));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = context.watch<ThemeProvider?>()?.frostedGlass == true;
    final dark = theme.brightness == Brightness.dark;
    final surfaceDecoration = decoration ??
        BoxDecoration(
          color: _rounded
              ? Colors.white.withValues(alpha: dark ? .08 : .5)
              : theme.colorScheme.surface,
          borderRadius:
              _rounded ? BorderRadius.circular(AppRadius.lg) : BorderRadius.zero,
        );
    final radius = surfaceDecoration.borderRadius ?? BorderRadius.zero;
    final neutral =
        theme.brightness == Brightness.dark ? Colors.white : Colors.black;
    return AppCardSurface(
      height: _surfaceHeight,
      width: width,
      margin: margin,
      padding: padding,
      alignment: alignment,
      decoration: surfaceDecoration,
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
