import 'package:flutter/material.dart';

/// 全局颜色 token 与语义系统。
abstract final class AppColors {
  // Brand Tokens
  static const brandPrimary = Color(0xFF147C72);
  static const brandPrimaryStrong = Color(0xFF0F635B);
  static const brandSurfaceLight = Color(0xFFEAF6F3);
  static const brandSurfaceDark = Color(0xFF162B28);

  // Status Tokens
  static const success = Color(0xFF169B5B);
  static const successSurfaceLight = Color(0xFFE8F7EE);
  static const successSurfaceDark = Color(0xFF142B1F);

  static const warning = Color(0xFFF59E0B);
  static const warningSurfaceLight = Color(0xFFFFF3DD);
  static const warningSurfaceDark = Color(0xFF2E2413);

  static const danger = Color(0xFFE54848);
  static const dangerSurfaceLight = Color(0xFFFFEAEA);
  static const dangerSurfaceDark = Color(0xFF2D1818);

  static const info = Color(0xFF426C85);
  static const infoSurfaceLight = Color(0xFFEAF2F6);
  static const infoSurfaceDark = Color(0xFF18242C);

  // Surface Tokens
  static const surfacePrimaryLight = Color(0xFFFFFAF4);
  static const surfaceSecondaryLight = Colors.white;
  static const surfaceMutedLight = Color(0xFFF2F3F1);
  static const surfaceFocusedLight = Color(0xFFEFF4F1);
  static const surfacePrimaryDark = Color(0xFF111315);
  static const surfaceSecondaryDark = Color(0xFF1A1D1F);
  static const surfaceMutedDark = Color(0xFF24282A);
  static const surfaceFocusedDark = Color(0xFF2B3033);

  // Text Tokens
  static const textPrimaryLight = Color(0xFF1F2328);
  static const textSecondaryLight = Color(0xFF747B82);
  static const textMutedLight = Color(0xFF858C89);
  static const textTertiaryLight = Color(0xFF9AA1A1);
  static const textPrimaryDark = Color(0xFFF2F4F3);
  static const textSecondaryDark = Color(0xFFA7AFAB);
  static const textTertiaryDark = Color(0xFF8E9894);

  // Border Tokens
  static const borderNormalLight = Color(0xFFE2EFEA);
  static const borderSubtleLight = Color(0xFFE8EEE9);
  static const borderNormalDark = Color(0xFF303638);
  static const borderSubtleDark = Color(0xFF252A2C);

  // 首页 Feed 轻量状态表面：用于版块 badge 与弱化的精华 badge。
  static const feedSectionSurfaceLight = Color(0xFFE8F5F1);
  static const feedFeaturedSurfaceLight = Color(0xFFFFF3E0);
  static const feedFeaturedTextLight = Color(0xFFD97706);
  static const feedFeaturedSurfaceDark = Color(0xFF3A2A18);
  static const feedFeaturedTextDark = Color(0xFFF2B15A);

  // Composer & Control Tokens
  static const composerSurfaceLight = Color(0xFFFFFFFF);
  static const composerSurfaceDark = Color(0xFF181B1D);
  static const composerInputLight = Color(0xFFF2F3F1);
  static const composerInputFocusedLight = Color(0xFFEFF4F1);
  static const composerInputDark = Color(0xFF24282A);
  static const composerInputFocusedDark = Color(0xFF2B3033);
  static const composerDividerLight = Color(0xFFE8EEE9);
  static const composerDividerDark = Color(0xFF303638);

  // Search Bar
  static const searchBarFillLight = Color(0xFFF1F2F0);
  static const searchBarFillDark = Color(0xFF24282A);

  // Chat Message Bubbles
  static const messageIncomingLight = Color(0xFFF0F1EF);
  static const messageIncomingBorderLight = Color(0xFFE2E5E1);
  static const messageIncomingDark = Color(0xFF262A2C);
  static const messageIncomingBorderDark = Color(0xFF323739);
  // Chat Message Bubbles & Send Button (Classic Sky Blue with high-contrast text)
  static const messageOutgoingLight = Color(0xFF76C4FF);
  static const messageOutgoingDark = Color(0xFF80C4FC);
  static const messageOutgoingTextLight = Color(0xFF1F2328);
  static const messageOutgoingTextDark = Color(0xFF111315);

  // Icons & Disabled States
  static const iconNeutralLight = Color(0xFF626966);
  static const iconNeutralDark = Color(0xFFB1B8B4);
  static const iconMutedLight = Color(0xFF858C89);
  static const iconMutedDark = Color(0xFF707874);
  static const disabledControlLight = Color(0xFFF2F3F1);
  static const disabledControlDark = Color(0xFF24282A);
  static const disabledControlTextLight = Color(0xFFB8BDBA);
  static const disabledControlTextDark = Color(0xFF5A615D);

  // ==================================================================
  //  分数与成绩语义 Helper 函数
  // ==================================================================

  /// 分数前景色语义：
  /// - 90 ~ 100: 优秀/高分 -> 绿色 (success)
  /// - 60 ~ 89: 达标/普通 -> 品牌青绿 (brandPrimary)
  /// - < 60: 不及格/低分 -> 红色 (danger)
  static Color scoreColor(num score) {
    if (score >= 90) return success;
    if (score >= 60) return brandPrimary;
    return danger;
  }

  /// 分数背景色语义
  static Color scoreSurface(num score, {required bool isDark}) {
    if (score >= 90) {
      return isDark ? successSurfaceDark : successSurfaceLight;
    }
    if (score >= 60) {
      return isDark ? brandSurfaceDark : brandSurfaceLight;
    }
    return isDark ? dangerSurfaceDark : dangerSurfaceLight;
  }

  /// 评级文字前景色语义 (优秀/良好/及格/不及格)
  static Color gradeStatusColor(String grade) {
    final trimmed = grade.trim();
    if (trimmed == '优秀') return success;
    if (trimmed == '良好' || trimmed == '及格' || trimmed == '正常') {
      return brandPrimary;
    }
    if (trimmed == '不及格' ||
        trimmed.contains('未通过') ||
        trimmed.contains('不合格')) {
      return danger;
    }
    return textSecondaryLight;
  }

  /// 评级背景色语义
  static Color gradeStatusSurface(String grade, {required bool isDark}) {
    final trimmed = grade.trim();
    if (trimmed == '优秀') {
      return isDark ? successSurfaceDark : successSurfaceLight;
    }
    if (trimmed == '良好' || trimmed == '及格' || trimmed == '正常') {
      return isDark ? brandSurfaceDark : brandSurfaceLight;
    }
    if (trimmed == '不及格' ||
        trimmed.contains('未通过') ||
        trimmed.contains('不合格')) {
      return isDark ? dangerSurfaceDark : dangerSurfaceLight;
    }
    return isDark ? surfaceMutedDark : surfaceMutedLight;
  }
}
