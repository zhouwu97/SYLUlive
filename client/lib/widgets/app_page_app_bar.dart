import 'package:flutter/material.dart';

import 'campus/campus_theme.dart';

/// 应用内二级页面统一顶栏，避免不同模块各自覆盖高度与标题样式。
class AppPageAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppPageAppBar({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
    this.automaticallyImplyLeading = true,
    this.leading,
  });

  final Widget title;
  final List<Widget> actions;
  final bool automaticallyImplyLeading;
  final Widget? leading;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppBar(
      automaticallyImplyLeading: automaticallyImplyLeading,
      leading: leading,
      leadingWidth: 56,
      toolbarHeight: preferredSize.height,
      centerTitle: true,
      titleSpacing: 0,
      backgroundColor: CampusTheme.pageBackground(context),
      foregroundColor: theme.colorScheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: theme.textTheme.titleMedium?.copyWith(
        color: theme.colorScheme.onSurface,
        fontSize: 17,
        fontWeight: FontWeight.w700,
      ),
      title: title,
      actions: actions,
    );
  }
}
