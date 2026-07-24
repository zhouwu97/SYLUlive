import 'package:flutter/material.dart';

/// Shared design tokens for the ranking/evaluation system.
/// Different ranking categories use different accent colours so
/// the whole system no longer relies on a single purple palette.
final class RankingTokens {
  RankingTokens._();

  // ── Base palette (shared with campus / competition) ────────────────
  static Color pageBg(bool isDark) =>
      isDark ? const Color(0xFF111315) : const Color(0xFFF6F7F8);

  static Color cardBg(bool isDark) =>
      isDark ? const Color(0xFF1E2226) : Colors.white;

  static Color borderColor(bool isDark) =>
      isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE9E7E2);

  static Color titleColor(bool isDark) =>
      isDark ? Colors.white : const Color(0xFF1F2328);

  static Color subColor(bool isDark) =>
      isDark ? Colors.grey.shade400 : const Color(0xFF7A7F87);

  static Color mutedColor(bool isDark) =>
      isDark ? Colors.white38 : const Color(0xFF98A2B3);

  // ── Per-category accents ───────────────────────────────────────────

  /// Canteen / dining — warm amber-orange
  static Color canteenAccent(bool isDark) =>
      isDark ? const Color(0xFFFBBF24) : const Color(0xFFF59E0B);
  static Color canteenAccentSoft(bool isDark) => isDark
      ? const Color(0xFFFBBF24).withValues(alpha: 0.12)
      : const Color(0xFFFFF4DE);

  /// Teacher / subject — blue-green (teal)
  static Color teacherAccent(bool isDark) =>
      isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
  static Color teacherAccentSoft(bool isDark) => isDark
      ? const Color(0xFF7ED6C5).withValues(alpha: 0.12)
      : const Color(0xFFEAF6F3);

  /// Major — indigo / slate-blue
  static Color majorAccent(bool isDark) =>
      isDark ? const Color(0xFF93A9D1) : const Color(0xFF5D78A7);
  static Color majorAccentSoft(bool isDark) => isDark
      ? const Color(0xFF93A9D1).withValues(alpha: 0.12)
      : const Color(0xFFEDF3FA);

  /// Price / hot colour — kept for prices on market cards etc.
  static Color priceColor(bool _) => const Color(0xFFE76F51);

  /// Success green
  static Color successColor(bool _) => const Color(0xFF16A34A);
  static Color successSoft(bool isDark) => isDark
      ? const Color(0xFF16A34A).withValues(alpha: 0.15)
      : const Color(0xFFDCFCE7);

  /// Warning
  static Color warningColor(bool _) => const Color(0xFFF59E0B);

  /// Gold / silver / bronze for rank badges
  static const Color rankGold = Color(0xFFFFB800);
  static const Color rankSilver = Color(0xFF94A3B8);
  static const Color rankBronze = Color(0xFFCA8A4B);

  // ── Spacing / sizing ───────────────────────────────────────────────
  static const double pageH = 16.0;
  static const double cardRadius = 16.0;
  static const double chipRadius = 999.0;
  static const double cardPadding = 14.0;
  static const double cardGap = 10.0;
  static const double sectionGap = 14.0;
  static const double searchHeight = 46.0;
  static const double tabHeight = 38.0;
  static const double listItemHeight = 88.0;

  // ── Decorations ────────────────────────────────────────────────────
  static BoxDecoration cardDecoration(
    bool isDark, {
    Color? overrideColor,
    Color? borderOverride,
  }) {
    return BoxDecoration(
      color: overrideColor ?? cardBg(isDark),
      borderRadius: BorderRadius.circular(cardRadius),
      border: Border.all(
        color: borderOverride ?? borderColor(isDark),
        width: 0.5,
      ),
    );
  }
}
