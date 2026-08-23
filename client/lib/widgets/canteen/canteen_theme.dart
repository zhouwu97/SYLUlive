import 'package:flutter/material.dart';

/// 校园餐饮 Feature Token。
///
/// 餐饮视觉作为独立 Feature Token 收敛，不再依赖 RankingTokens，
/// 校园榜单改主题时不会把餐饮一起带跑（见 DESIGN_SYSTEM Known Debt #9）。
abstract final class CanteenTheme {
  CanteenTheme._();

  // ── Light tokens ────────────────────────────────────────────
  static const Color page = Color(0xFFF8F7F4); // 页面背景（中性暖白）
  static const Color surface = Color(0xFFFFFFFF); // 内容 surface
  static const Color surfaceMuted = Color(0xFFF2F1ED); // 浅灰底（filter chip 未选中 / 占位）
  static const Color textPrimary = Color(0xFF202124);
  static const Color textSecondary = Color(0xFF777B82);
  static const Color textTertiary = Color(0xFFA0A4AA);
  static const Color border = Color(0xFFEAE8E3);
  static const Color accent = Color(0xFFF3921F); // 少量暖橙（★ / CTA / 选中）
  static const Color accentStrong = Color(0xFFD97706);
  static const Color accentSoft = Color(0xFFFFF1DF); // 选中 chip 底

  // ── 排名排版色（纯文字，无底色 / 无 badge / 无阴影）────────────
  static const Color rank1 = Color(0xFFD68A20);
  static const Color rank2 = Color(0xFF87909A);
  static const Color rank3 = Color(0xFFA66A43);
  static const Color rankN = Color(0xFFB0B3B7);

  // ── Radius ─────────────────────────────────────────────────
  static const double radiusSm = 10; // chip / 小控件
  static const double radiusMd = 14; // 图片圆角
  static const double radiusLg = 20; // hero 底部过渡 / 大型 surface

  // ── isDark-aware accessors ─────────────────────────────────
  static Color pageBg(bool isDark) => isDark ? const Color(0xFF111315) : page;
  static Color surfaceBg(bool isDark) =>
      isDark ? const Color(0xFF1E2226) : surface;
  static Color surfaceMutedBg(bool isDark) =>
      isDark ? const Color(0xFF24282C) : surfaceMuted;
  static Color textPrimaryColor(bool isDark) =>
      isDark ? const Color(0xFFF1F3F4) : textPrimary;
  static Color textSecondaryColor(bool isDark) =>
      isDark ? const Color(0xFF9AA0A6) : textSecondary;
  static Color textTertiaryColor(bool isDark) =>
      isDark ? const Color(0xFF6B7075) : textTertiary;
  static Color borderColor(bool isDark) =>
      isDark ? const Color(0xFF2C3033) : border;
  static Color accentColor(bool isDark) =>
      isDark ? const Color(0xFFFBBF24) : accent;
  static Color accentStrongColor(bool isDark) =>
      isDark ? const Color(0xFFF59E0B) : accentStrong;
  static Color accentSoftColor(bool isDark) => isDark
      ? const Color(0xFFFBBF24).withValues(alpha: 0.12)
      : accentSoft;

  static Color rankColor(int rank) => switch (rank) {
        1 => rank1,
        2 => rank2,
        3 => rank3,
        _ => rankN,
      };
}
