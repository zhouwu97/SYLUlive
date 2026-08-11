import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

/// 统一的设置中心页面脚手架 (恢复 18dp 标准舒服边距)
class SettingsPageScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final Future<void> Function()? onRefresh;

  const SettingsPageScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final isDark = baseTheme.brightness == Brightness.dark;
    final pageBg = CampusTheme.pageBackground(context);

    Widget content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.only(
            left: 18,
            right: 18,
            top: 8,
            bottom: 24,
          ),
          children: children,
        ),
      ),
    );

    if (onRefresh != null) {
      content = RefreshIndicator(
        onRefresh: onRefresh!,
        color: CampusTheme.primary,
        child: content,
      );
    }

    return Theme(
      data: CampusTheme.withBrandAccent(baseTheme),
      child: Scaffold(
        backgroundColor: pageBg,
        appBar: AppBar(
          title: Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : CampusTheme.text,
            ),
          ),
          centerTitle: false,
          backgroundColor: pageBg,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          elevation: 0,
          iconTheme: IconThemeData(
            color: isDark ? Colors.white : CampusTheme.text,
          ),
          actions: actions,
        ),
        body: SafeArea(
          top: false,
          child: content,
        ),
      ),
    );
  }
}
