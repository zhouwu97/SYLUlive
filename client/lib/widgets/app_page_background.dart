import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/theme_provider.dart';
import 'global_background_wrapper.dart';

/// 普通二级内容页共用的背景入口，覆盖加载、空数据和失败分支。
/// 页面仍保留自己的 Scaffold、导航、表单状态和滚动控制器。
class AppPageBackground extends StatelessWidget {
  const AppPageBackground({super.key, required this.builder});

  final WidgetBuilder builder;

  static Color? color(BuildContext context, Color? fallback) =>
      context.watch<ThemeProvider?>()?.shouldShowCustomBackground == true
          ? Colors.transparent
          : fallback;

  @override
  Widget build(BuildContext context) {
    final appearance = context.watch<ThemeProvider?>();
    if (appearance == null) return Builder(builder: builder);
    final theme = Theme.of(context);
    final custom = appearance.shouldShowCustomBackground;
    return GlobalBackgroundWrapper(
      child: Theme(
        data: custom
            ? theme.copyWith(
                scaffoldBackgroundColor: Colors.transparent,
                appBarTheme: theme.appBarTheme.copyWith(
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                ),
              )
            : theme,
        child: Builder(builder: builder),
      ),
    );
  }
}
