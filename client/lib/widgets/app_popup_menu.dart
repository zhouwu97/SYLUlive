import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import '../theme/app_radius.dart';
import 'app_card.dart';

/// 菜单路由保留原条目、键盘操作和返回值，仅用一层共用玻璃承载菜单。
class AppPopupMenuButton<T> extends StatelessWidget {
  const AppPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.onOpened,
    this.onCanceled,
    this.icon,
    this.child,
    this.tooltip,
    this.color,
    this.shape,
    this.elevation,
    this.padding = const EdgeInsets.all(8),
    this.offset = Offset.zero,
    this.enabled = true,
    this.iconSize,
    this.constraints,
    this.position,
    this.useRootNavigator = false,
    this.surfaceTintColor,
    this.shadowColor,
    this.menuPadding,
    this.initialValue,
  });

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final VoidCallback? onOpened;
  final VoidCallback? onCanceled;
  final Widget? icon;
  final Widget? child;
  final String? tooltip;
  final Color? color;
  final ShapeBorder? shape;
  final double? elevation;
  final EdgeInsetsGeometry padding;
  final Offset offset;
  final bool enabled;
  final double? iconSize;
  final BoxConstraints? constraints;
  final PopupMenuPosition? position;
  final bool useRootNavigator;
  final Color? surfaceTintColor;
  final Color? shadowColor;
  final EdgeInsetsGeometry? menuPadding;
  final T? initialValue;

  @override
  Widget build(BuildContext context) {
    final glass = context.watch<ThemeProvider?>()?.frostedGlass == true;
    final theme = PopupMenuTheme.of(context);
    final menuShape = shape ??
        theme.shape ??
        const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg)));
    final glassShape = menuShape is OutlinedBorder
        ? menuShape.copyWith(side: BorderSide.none)
        : menuShape;
    return PopupMenuButton<T>(
      initialValue: initialValue,
      icon: icon,
      tooltip: tooltip,
      onSelected: onSelected,
      onOpened: onOpened,
      onCanceled: onCanceled,
      padding: padding,
      offset: offset,
      enabled: enabled,
      iconSize: iconSize,
      constraints: constraints,
      position: position,
      useRootNavigator: useRootNavigator,
      color: glass ? Colors.transparent : color,
      elevation: glass ? 0 : elevation,
      surfaceTintColor: glass ? Colors.transparent : surfaceTintColor,
      shadowColor: glass ? Colors.transparent : shadowColor,
      shape: glass ? glassShape : shape,
      clipBehavior: glass ? Clip.antiAlias : Clip.none,
      menuPadding: glass ? EdgeInsets.zero : menuPadding,
      itemBuilder: (menuContext) {
        final entries = itemBuilder(menuContext);
        if (!glass || entries.isEmpty) return entries;
        return [
          _GlassMenuGroup<T>(
            entries: entries,
            color: color ??
                theme.color ??
                Theme.of(context).colorScheme.surfaceContainer,
            shape: glassShape,
            padding: menuPadding ??
                theme.menuPadding ??
                const EdgeInsets.symmetric(vertical: 8),
          )
        ];
      },
      child: child,
    );
  }
}

class _GlassMenuGroup<T> extends PopupMenuEntry<T> {
  const _GlassMenuGroup(
      {required this.entries,
      required this.color,
      required this.shape,
      required this.padding});
  final List<PopupMenuEntry<T>> entries;
  final Color color;
  final ShapeBorder shape;
  final EdgeInsetsGeometry padding;
  @override
  double get height =>
      entries.fold<double>(0, (sum, entry) => sum + entry.height) +
      padding.vertical;
  // 原条目自行保留选中状态，避免路由将整个菜单染为选中背景。
  @override
  bool represents(T? value) => false;
  @override
  State<_GlassMenuGroup<T>> createState() => _GlassMenuGroupState<T>();
}

class _GlassMenuGroupState<T> extends State<_GlassMenuGroup<T>> {
  @override
  Widget build(BuildContext context) => AppCardMaterial(
        color: widget.color,
        shape: widget.shape,
        clipBehavior: Clip.antiAlias,
        child: Padding(
            padding: widget.padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: widget.entries
                  .map<Widget>((entry) => entry is PopupMenuDivider
                      ? SizedBox(height: entry.height)
                      : entry)
                  .toList(growable: false),
            )),
      );
}
