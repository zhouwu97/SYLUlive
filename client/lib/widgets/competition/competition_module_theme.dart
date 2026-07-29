import 'package:flutter/material.dart';

import 'competition_ui_tokens.dart';

class CompetitionModuleTheme {
  const CompetitionModuleTheme._();

  static ThemeData of(BuildContext context) {
    final base = Theme.of(context);
    final isDark = base.brightness == Brightness.dark;
    final accent = CompetitionUiTokens.accent(isDark);
    final foreground = CompetitionUiTokens.titleColor(isDark);
    final border = CompetitionUiTokens.borderColor(isDark);
    final colorScheme = base.colorScheme.copyWith(
      primary: accent,
      secondary: accent,
      surface: CompetitionUiTokens.cardBg(isDark),
      onSurface: foreground,
    );
    final compactChipShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(CompetitionUiTokens.controlRadius),
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: CompetitionUiTokens.pageBg(isDark),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: CompetitionUiTokens.pageBg(isDark),
        foregroundColor: foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
      ),
      progressIndicatorTheme:
          base.progressIndicatorTheme.copyWith(color: accent),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: isDark ? const Color(0xFF10211E) : Colors.white,
          disabledBackgroundColor: accent.withValues(alpha: 0.28),
          minimumSize: const Size(48, 44),
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(CompetitionUiTokens.controlRadius),
          ),
        ),
      ),
      floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
        backgroundColor: accent,
        foregroundColor: isDark ? const Color(0xFF10211E) : Colors.white,
        elevation: 1,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : CompetitionUiTokens.subColor(isDark),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accent
              : border,
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: CompetitionUiTokens.cardBg(isDark),
        selectedColor: CompetitionUiTokens.accentSoft(isDark),
        checkmarkColor: accent,
        side: BorderSide(color: border),
        shape: compactChipShape,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        labelPadding: const EdgeInsets.symmetric(horizontal: 2),
        visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 40)),
          visualDensity:
              const WidgetStatePropertyAll(VisualDensity(vertical: -1)),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? Colors.white : foreground,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? accent
                : CompetitionUiTokens.cardBg(isDark),
          ),
          side: WidgetStatePropertyAll(BorderSide(color: border)),
        ),
      ),
    );
  }
}
