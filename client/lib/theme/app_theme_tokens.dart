import 'package:flutter/material.dart';
import 'app_colors.dart';
import '../widgets/campus/campus_theme.dart';

/// 统一主题 Token 访问器（Theme Token）
///
/// 消除新页面与改造页面中的硬编码颜色，严格自适应浅色与深色系统模式。
class AppThemeTokens {
  final BuildContext context;
  const AppThemeTokens(this.context);

  static AppThemeTokens of(BuildContext context) => AppThemeTokens(context);

  bool get isDark => Theme.of(context).brightness == Brightness.dark;

  Color get background =>
      isDark ? AppColors.surfacePrimaryDark : CampusTheme.bg;

  Color get surface =>
      isDark ? AppColors.surfaceSecondaryDark : AppColors.surfaceSecondaryLight;

  Color get surfaceElevated =>
      isDark ? const Color(0xFF232729) : const Color(0xFFFFFFFF);

  Color get textPrimary =>
      isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;

  Color get textSecondary =>
      isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

  Color get textDisabled =>
      isDark ? AppColors.disabledControlTextDark : AppColors.disabledControlTextLight;

  Color get primary =>
      isDark ? const Color(0xFF7ED6C5) : AppColors.brandPrimary;

  Color get onPrimary =>
      isDark ? const Color(0xFF0F2622) : Colors.white;

  Color get divider =>
      isDark ? AppColors.borderSubtleDark : AppColors.borderSubtleLight;

  Color get outline =>
      isDark ? AppColors.borderNormalDark : AppColors.borderNormalLight;

  Color get error => AppColors.danger;
  Color get warning => AppColors.warning;
  Color get success => AppColors.success;

  Color get inputBackground =>
      isDark ? AppColors.composerInputDark : AppColors.composerInputLight;

  Color get cardBackground =>
      isDark ? const Color(0xFF1A1D1F) : Colors.white;

  Color get courseCardText =>
      isDark ? Colors.white : const Color(0xFF1F2328);

  Color get overlay =>
      isDark ? Colors.black54 : Colors.black26;

  Color get tagBackground =>
      isDark ? const Color(0xFF282D30) : const Color(0xFFEEF2F0);

  Color get tagText =>
      isDark ? const Color(0xFF90D5C7) : AppColors.brandPrimary;
}
