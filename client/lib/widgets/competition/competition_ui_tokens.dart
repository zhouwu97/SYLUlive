import 'package:flutter/material.dart';

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

  static Color upcomingColor(bool isDark) =>
      isDark ? const Color(0xFFE57373) : const Color(0xFFE76F51);

  static Color pendingColor(bool isDark) =>
      isDark ? const Color(0xFF90A4AE) : const Color(0xFF7D8A97);

  static Color archivedColor(bool isDark) =>
      isDark ? const Color(0xFF78909C) : const Color(0xFFB8BFC6);

  // --- Dimensions ---
  static const double pagePadding = 16.0;
  static const double cardRadius = 18.0;
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
