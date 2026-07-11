import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

class TeamUiTokens {
  static const double pagePadding = 16;
  static const double cardRadius = 18;
  static const double fieldRadius = 14;
  static const double sectionGap = 16;

  static Color pageBg(bool isDark) =>
      isDark ? CampusTheme.darkBg : CampusTheme.bg;

  static Color cardBg(bool isDark) =>
      isDark ? CampusTheme.darkCard : CampusTheme.card;

  static Color accent(bool isDark) =>
      isDark ? const Color(0xFF7ED6C5) : CampusTheme.primary;

  static Color accentSoft(bool isDark) => isDark
      ? const Color(0xFF7ED6C5).withValues(alpha: 0.12)
      : CampusTheme.primaryLight;

  static Color border(bool isDark) =>
      isDark ? Colors.white.withValues(alpha: 0.08) : CampusTheme.border;

  static Color title(bool isDark) => isDark ? Colors.white : CampusTheme.text;

  static Color subtitle(bool isDark) =>
      isDark ? Colors.white60 : CampusTheme.subText;

  static ButtonStyle primaryButtonStyle(bool isDark) {
    final color = accent(isDark);
    return FilledButton.styleFrom(
      backgroundColor: color,
      foregroundColor: Colors.white,
      disabledBackgroundColor: color.withValues(alpha: 0.35),
      disabledForegroundColor: Colors.white.withValues(alpha: 0.8),
    );
  }

  static ButtonStyle secondaryButtonStyle(bool isDark) {
    return OutlinedButton.styleFrom(
      foregroundColor: accent(isDark),
      side: BorderSide(color: accent(isDark).withValues(alpha: 0.5)),
    );
  }
}
