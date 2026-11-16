import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_palette.dart';

/// 统一主题 Token 访问器，公开名称保留给已迁移页面。
class AppThemeTokens {
  const AppThemeTokens(this.context);

  final BuildContext context;
  static AppThemeTokens of(BuildContext context) => AppThemeTokens(context);

  AppPalette get _palette {
    final theme = Theme.of(context);
    return theme.extension<AppPalette>() ??
        AppPalette.defaults(theme.brightness);
  }

  bool get isDark => Theme.of(context).brightness == Brightness.dark;

  Color get primary => _palette.primary;
  Color get onPrimary => _palette.onPrimary;
  Color get primaryContainer => _palette.primaryContainer;
  Color get onPrimaryContainer => _palette.onPrimaryContainer;
  Color get background => _palette.background;
  Color get surface => _palette.surface;
  Color get surfaceElevated => _palette.surfaceElevated;
  Color get surfaceMuted => _palette.surfaceMuted;
  Color get card => _palette.card;
  Color get cardBorder => _palette.cardBorder;
  Color get textPrimary => _palette.textPrimary;
  Color get textSecondary => _palette.textSecondary;
  Color get textTertiary => _palette.textTertiary;
  Color get textDisabled => _palette.textDisabled;
  Color get divider => _palette.divider;
  Color get outline => _palette.outline;
  Color get inputFill => _palette.inputFill;
  Color get inputFillFocused => _palette.inputFillFocused;
  Color get searchFill => _palette.searchFill;
  Color get tagBackground => _palette.tagBackground;
  Color get tagText => _palette.tagText;
  Color get navBackground => _palette.navBackground;
  Color get navSelected => _palette.navSelected;
  Color get navUnselected => _palette.navUnselected;
  Color get appBarBackground => _palette.appBarBackground;
  Color get appBarForeground => _palette.appBarForeground;
  Color get bubbleIncoming => _palette.bubbleIncoming;
  Color get bubbleIncomingText => _palette.bubbleIncomingText;
  Color get bubbleOutgoing => _palette.bubbleOutgoing;
  Color get bubbleOutgoingText => _palette.bubbleOutgoingText;
  Color get feedSectionSurface => _palette.feedSectionSurface;
  Color get feedFeaturedSurface => _palette.feedFeaturedSurface;
  Color get feedFeaturedText => _palette.feedFeaturedText;
  Color get courseCardText => _palette.courseCardText;
  Color get timetableGrid => _palette.timetableGrid;
  Color get timetableToday => _palette.timetableToday;
  List<Color> get coursePalette => _palette.coursePalette;

  Color get inputBackground => inputFill;
  Color get cardBackground => card;
  Color get error => AppColors.danger;
  Color get warning => AppColors.warning;
  Color get success => AppColors.success;
  Color get overlay => isDark ? Colors.black54 : Colors.black26;
}
