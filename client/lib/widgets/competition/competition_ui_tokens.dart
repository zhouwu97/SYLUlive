import 'package:flutter/material.dart';

import '../campus/campus_theme.dart';

class CompetitionUiTokens {
  // --- Colors ---
  static Color pageBg(bool isDark) =>
      isDark ? const Color(0xFF111315) : const Color(0xFFFFFAF4);

  static Color cardBg(bool isDark) =>
      isDark ? const Color(0xFF1E2226) : Colors.white;

  static Color accent(bool isDark) =>
      isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);

  static Color accentSoft(bool isDark) => isDark
      ? const Color(0xFF7ED6C5).withValues(alpha: 0.12)
      : const Color(0xFFEAF6F3);

  static Color borderColor(bool isDark) =>
      isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE6EFEA);

  static Color titleColor(bool isDark) =>
      isDark ? Colors.white : const Color(0xFF1F2328);

  static Color subColor(bool isDark) =>
      isDark ? Colors.grey.shade400 : const Color(0xFF747B82);

  static Color dangerColor(bool isDark) =>
      isDark ? const Color(0xFFFF8A80) : const Color(0xFFE54848);

  static Color warningColor(bool isDark) =>
      isDark ? const Color(0xFFFFB74D) : const Color(0xFFF2994A);

  /// 警告类提示的浅底，与 accentSoft 同构，避免各页面各自手调透明度。
  static Color warningSoft(bool isDark) =>
      warningColor(isDark).withValues(alpha: 0.12);

  static Color upcomingColor(bool isDark) =>
      isDark ? const Color(0xFFE57373) : const Color(0xFFE76F51);

  static Color pendingColor(bool isDark) =>
      isDark ? const Color(0xFF90A4AE) : const Color(0xFF7D8A97);

  static Color archivedColor(bool isDark) =>
      isDark ? const Color(0xFF78909C) : const Color(0xFFB8BFC6);

  // --- 匹配度语义色 ---
  //
  // 只服务「匹配度」这一个维度：不得与人工评级（competition_rating）的展示混用，
  // 也不得替代成功/错误这类全局状态语义（ACCESSIBILITY §Contrast）。
  // 浅色沿用设计系统登记的业务功能色（CampusTheme.green / cyan），
  // 深色用提亮变体以保证对比度；explore 复用中性的待确认色，避免暗示「好/坏」。
  static Color matchTierColor(String tier, bool isDark) {
    switch (tier.trim()) {
      case 'strong':
        return isDark ? const Color(0xFF6EE7B7) : CampusTheme.green;
      case 'suitable':
        return isDark ? const Color(0xFF5EEAD4) : CampusTheme.cyan;
      default:
        return pendingColor(isDark);
    }
  }

  /// 匹配度徽标的浅底，与 accentSoft 同构。
  static Color matchTierSoft(String tier, bool isDark) =>
      matchTierColor(tier, isDark).withValues(alpha: 0.12);

  // --- Dimensions ---
  static const double pagePadding = 16.0;
  static const double cardRadius = 18.0;
  static const double compactCardRadius = 14.0;
  static const double controlRadius = 10.0;
  static const double chipRadius = 999.0;

  // --- Decorations ---
  static BoxDecoration cardDecoration(bool isDark) {
    return BoxDecoration(
      color: cardBg(isDark),
      borderRadius: BorderRadius.circular(cardRadius),
      border: Border.all(color: borderColor(isDark)),
      boxShadow: isDark
          ? null
          : [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.025),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
    );
  }
}
