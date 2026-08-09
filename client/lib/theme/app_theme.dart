import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_radius.dart';
import '../widgets/campus/campus_theme.dart';

class AppTheme {
  // 主题色
  static const Color primaryColor = AppColors.accentIndigo;
  static const Color secondaryColor = AppColors.accentPurple;
  static const Color accentColor = AppColors.accentPink;

  // 圆角 — 国产 UI 紧凑风格
  static const double borderRadius = AppRadius.md;
  static const double borderRadiusSmall = AppRadius.sm;
  static const double borderRadiusLarge = AppRadius.lg;

  // 阴影
  static const double shadowBlur = 10.0;
  static const double shadowOffset = 2.0;

  // 间距 — 紧凑
  static const double spacing = 12.0;
  static const double spacingSmall = 6.0;
  static const double spacingLarge = 20.0;

  static ThemeData _baseTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor:
          brightness == Brightness.dark ? CampusTheme.darkBg : CampusTheme.bg,
      canvasColor:
          brightness == Brightness.dark ? CampusTheme.darkBg : CampusTheme.bg,
      fontFamily: 'NotoSansCJKsc',
      fontFamilyFallback: const [
        'Noto Color Emoji',
        'Segoe UI Emoji',
        'Apple Color Emoji',
      ],
      // 全局紧凑密度
      visualDensity: VisualDensity.compact,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 48,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      // 卡片 — 紧凑圆角
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
      // 按钮 — 紧凑
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        ),
      ),
      // 输入框 — 紧凑
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
      // 对话框 — 紧凑圆角
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadiusLarge),
        ),
      ),
      // 底部弹窗
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      // Tab 栏
      tabBarTheme: const TabBarThemeData(
        labelStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 14),
        indicatorSize: TabBarIndicatorSize.label,
      ),
      // 导航栏
      navigationBarTheme: NavigationBarThemeData(
        height: 60,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      // FloatingActionButton
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 2,
      ),
    );
  }

  static ThemeData get lightTheme => _baseTheme(Brightness.light);
  static ThemeData get darkTheme => _baseTheme(Brightness.dark);
}
