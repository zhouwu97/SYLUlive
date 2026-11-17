import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_palette.dart';
import 'app_radius.dart';

class AppTheme {
  // 主题色 — 全局统一为品牌青绿
  static const Color primaryColor = AppColors.brandPrimary;
  static const Color secondaryColor = AppColors.info;
  static const Color accentColor = AppColors.warning;

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

  static const List<String> defaultFontFallback = [
    'NotoSansCJKsc',
    'Noto Color Emoji',
    'Segoe UI Emoji',
    'Apple Color Emoji',
  ];

  static ThemeData build({
    required Brightness brightness,
    AppPalette? palette,
    AppShape shape = const AppShape(),
    Color seedColor = AppColors.brandPrimary,
    DynamicSchemeVariant variant = DynamicSchemeVariant.tonalSpot,
    String? fontFamily,
  }) {
    final effectiveFont = (fontFamily != null && fontFamily.isNotEmpty)
        ? fontFamily
        : 'NotoSansCJKsc';
    final colors = palette ?? AppPalette.defaults(brightness);
    var scheme = ColorScheme.fromSeed(
      seedColor: palette == null ? AppColors.brandPrimary : seedColor,
      brightness: brightness,
      dynamicSchemeVariant:
          palette == null ? DynamicSchemeVariant.tonalSpot : variant,
    );
    if (palette != null) {
      scheme = scheme.copyWith(
        primary: colors.primary,
        onPrimary: colors.onPrimary,
        primaryContainer: colors.primaryContainer,
        onPrimaryContainer: colors.onPrimaryContainer,
        surface: colors.background,
        onSurface: colors.textPrimary,
        onSurfaceVariant: colors.textSecondary,
        surfaceContainerLowest: colors.card,
        surfaceContainerLow: colors.surface,
        surfaceContainerHigh: colors.surfaceElevated,
        surfaceContainerHighest: colors.surfaceMuted,
        outline: colors.outline,
        outlineVariant: colors.divider,
      );
    }

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      extensions: [colors, shape],
      // 默认图标保留原有黑白前景，应用主题后跟随正文配色。
      iconTheme:
          palette == null ? null : IconThemeData(color: colors.textPrimary),
      // 默认亮色沿用 Material 主色，应用主题后才与语义主色对齐。
      primaryColor: palette == null && brightness == Brightness.light
          ? scheme.primary
          : colors.primary,
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.background,
      fontFamily: effectiveFont,
      fontFamilyFallback: defaultFontFallback,
      // 全局紧凑密度
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(
        color: colors.divider,
        thickness: 0.5,
      ),
      appBarTheme: AppBarTheme(
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: colors.appBarBackground,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 48,
        titleTextStyle: TextStyle(
          fontFamily: effectiveFont,
          fontFamilyFallback: defaultFontFallback,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: colors.appBarForeground,
        ),
      ),
      // 卡片 — 紧凑圆角
      cardTheme: CardThemeData(
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(shape.md),
        ),
      ),
      // 按钮 — 紧凑
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(shape.md),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          textStyle: TextStyle(
            fontFamily: effectiveFont,
            fontFamilyFallback: defaultFontFallback,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(shape.md),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          textStyle: TextStyle(
            fontFamily: effectiveFont,
            fontFamilyFallback: defaultFontFallback,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(shape.md),
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
          borderRadius: BorderRadius.circular(shape.md),
        ),
      ),
      // 对话框 — 紧凑圆角
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(shape.lg),
        ),
      ),
      // 底部弹窗
      bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(shape.lg)),
        ),
      ),
      // Tab 栏
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: colors.textSecondary,
        indicatorColor: scheme.primary,
        labelStyle: TextStyle(
          fontFamily: effectiveFont,
          fontFamilyFallback: defaultFontFallback,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: effectiveFont,
          fontFamilyFallback: defaultFontFallback,
          fontSize: 14,
        ),
        indicatorSize: TabBarIndicatorSize.label,
      ),
      // 进度条
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primary.withValues(alpha: 0.15),
      ),
      // Switch
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return palette == null ? Colors.white : colors.onPrimary;
          }
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return null;
        }),
      ),
      // 导航栏
      navigationBarTheme: NavigationBarThemeData(
        height: 60,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(shape.md),
        ),
      ),
      // FloatingActionButton
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 2,
      ),
    );
  }

  static ThemeData get lightTheme => build(brightness: Brightness.light);
  static ThemeData get darkTheme => build(brightness: Brightness.dark);
}
