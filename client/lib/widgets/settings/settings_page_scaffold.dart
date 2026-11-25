import 'package:flutter/material.dart';
import '../../theme/app_theme_tokens.dart';
import 'package:provider/provider.dart';
import '../../providers/theme_provider.dart';
import '../campus/campus_theme.dart';
import '../global_background_wrapper.dart';
import '../liquid_glass/liquid_glass_scene.dart';

/// 统一的设置中心页面脚手架 (恢复 18dp 标准舒服边距)
class SettingsPageScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final Future<void> Function()? onRefresh;

  /// 按需承托亮壁纸上的标题；默认仍使用原有顶栏背景。
  final Widget? appBarBackground;

  const SettingsPageScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.onRefresh,
    this.appBarBackground,
  });

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final appearance = context.watch<ThemeProvider?>();
    final pageBg = appearance?.hasSeeThroughBackground == true
        ? Colors.transparent
        : CampusTheme.pageBackground(context);

    Widget content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          addRepaintBoundaries: false,
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
        color: AppThemeTokens.of(context).primary,
        child: content,
      );
    }

    final page = Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        flexibleSpace: appBarBackground,
        title: Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppThemeTokens.of(context).textPrimary,
          ),
        ),
        centerTitle: false,
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        iconTheme: IconThemeData(
          color: AppThemeTokens.of(context).textPrimary,
        ),
        actions: actions,
      ),
      body: SafeArea(
        top: false,
        child: content,
      ),
    );
    return Theme(
      data: CampusTheme.withBrandAccent(baseTheme),
      child: LiquidGlassScene(
        background: Stack(fit: StackFit.expand, children: [
          if (appearance != null) const CustomBackgroundLayer(),
          ColoredBox(color: pageBg),
        ]),
        overlay: BackdropGroup(child: page),
      ),
    );
  }
}
