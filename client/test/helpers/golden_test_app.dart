import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:shenliyuan/theme/app_theme.dart';

/// 稳定、真实、最小的 SYLUlive App shell，供 golden / widget 测试包裹待测 widget。
///
/// 使用生产 Theme（`AppTheme.lightTheme` / `AppTheme.darkTheme`）与项目 CJK 字体
/// （配合 `load_test_fonts()`）。
///
/// **不注册任何业务 Provider / Dio mock**——AuthProvider、MessageProvider 等由
/// 具体测试自行包裹（见示例），避免本 helper 演变成「半套 AppBootstrap」。
///
/// 用法：
/// ```dart
/// GoldenTestApp(
///   home: MultiProvider(
///     providers: [...],
///     child: ChatDetailScreen(...),
///   ),
/// )
/// ```
class GoldenTestApp extends StatelessWidget {
  const GoldenTestApp({
    super.key,
    required this.home,
    this.themeMode = ThemeMode.light,
    this.textScaler = TextScaler.noScaling,
    this.disableAnimations = false,
  });

  final Widget home;
  final ThemeMode themeMode;
  final TextScaler textScaler;

  /// 置 true 时模拟系统「关闭动画」，用于 reduced-motion 场景测试。
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        var data = MediaQuery.of(context);
        if (disableAnimations) {
          data = data.copyWith(disableAnimations: true);
        }
        if (!identical(textScaler, TextScaler.noScaling)) {
          data = data.copyWith(textScaler: textScaler);
        }
        if (data == MediaQuery.of(context)) {
          return child ?? const SizedBox.shrink();
        }
        return MediaQuery(data: data, child: child ?? const SizedBox.shrink());
      },
      home: home,
    );
  }
}
