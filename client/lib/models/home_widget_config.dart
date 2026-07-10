import 'package:flutter/material.dart';

enum HomeWidgetKind {
  course,
  exam;

  String get storageName => name;

  String get defaultTitle => switch (this) {
        HomeWidgetKind.course => '沈理院课表',
        HomeWidgetKind.exam => '考试日程',
      };
}

enum HomeWidgetTheme {
  system,
  light,
  dark,
  campusBlue;

  String get storageName => name;

  String get label => switch (this) {
        HomeWidgetTheme.system => '跟随系统',
        HomeWidgetTheme.light => '浅色',
        HomeWidgetTheme.dark => '深色',
        HomeWidgetTheme.campusBlue => '校园蓝',
      };

  static HomeWidgetTheme fromStorage(String? value) {
    return HomeWidgetTheme.values.firstWhere(
      (theme) => theme.storageName == value,
      orElse: () => HomeWidgetTheme.system,
    );
  }

  /// 旧版本保存的是文字颜色。浅色文字对应深色背景，其余迁移为浅色主题。
  static HomeWidgetTheme fromLegacyTextColor(String? color) {
    final normalized = color?.trim().toUpperCase();
    if (normalized == '#FFFFFF' || normalized == '#FFF') {
      return HomeWidgetTheme.dark;
    }
    return HomeWidgetTheme.light;
  }
}

enum HomeWidgetSize {
  size2x2,
  size2x4;

  String get channelName => switch (this) {
        HomeWidgetSize.size2x2 => '2x2',
        HomeWidgetSize.size2x4 => '2x4',
      };

  String get label => switch (this) {
        HomeWidgetSize.size2x2 => '2×2 紧凑版',
        HomeWidgetSize.size2x4 => '2×4 列表版',
      };
}

class HomeWidgetAppearance {
  const HomeWidgetAppearance({
    required this.kind,
    required this.theme,
    required this.title,
  });

  final HomeWidgetKind kind;
  final HomeWidgetTheme theme;
  final String title;

  HomeWidgetAppearance copyWith({
    HomeWidgetTheme? theme,
    String? title,
  }) {
    return HomeWidgetAppearance(
      kind: kind,
      theme: theme ?? this.theme,
      title: title ?? this.title,
    );
  }
}

class HomeWidgetPreferenceKeys {
  const HomeWidgetPreferenceKeys._();

  static const courseTheme = 'widget_course_theme';
  static const examTheme = 'widget_exam_theme';
  static const courseTitle = 'widget_course_title';
  static const examTitle = 'widget_exam_title';

  static const legacyTextColor = 'widget_text_color';
  static const legacyTitle = 'widget_title';

  static String theme(HomeWidgetKind kind) => switch (kind) {
        HomeWidgetKind.course => courseTheme,
        HomeWidgetKind.exam => examTheme,
      };

  static String title(HomeWidgetKind kind) => switch (kind) {
        HomeWidgetKind.course => courseTitle,
        HomeWidgetKind.exam => examTitle,
      };
}

class HomeWidgetThemePalette {
  const HomeWidgetThemePalette({
    required this.background,
    required this.primaryText,
    required this.secondaryText,
    required this.mutedText,
    required this.accent,
    required this.border,
  });

  final Color background;
  final Color primaryText;
  final Color secondaryText;
  final Color mutedText;
  final Color accent;
  final Color border;

  static HomeWidgetThemePalette resolve(
    HomeWidgetTheme theme, {
    required Brightness systemBrightness,
  }) {
    final resolved = theme == HomeWidgetTheme.system
        ? (systemBrightness == Brightness.dark
            ? HomeWidgetTheme.dark
            : HomeWidgetTheme.light)
        : theme;

    return switch (resolved) {
      HomeWidgetTheme.dark => const HomeWidgetThemePalette(
          background: Color(0xF21F2937),
          primaryText: Color(0xFFF9FAFB),
          secondaryText: Color(0xFFD1D5DB),
          mutedText: Color(0xFF9CA3AF),
          accent: Color(0xFF60A5FA),
          border: Color(0xFF374151),
        ),
      HomeWidgetTheme.campusBlue => const HomeWidgetThemePalette(
          background: Color(0xF2EFF6FF),
          primaryText: Color(0xFF1E3A8A),
          secondaryText: Color(0xFF475569),
          mutedText: Color(0xFF94A3B8),
          accent: Color(0xFF3B82F6),
          border: Color(0xFFBFDBFE),
        ),
      HomeWidgetTheme.light ||
      HomeWidgetTheme.system =>
        const HomeWidgetThemePalette(
          background: Color(0xF2FFFFFF),
          primaryText: Color(0xFF111827),
          secondaryText: Color(0xFF4B5563),
          mutedText: Color(0xFF9CA3AF),
          accent: Color(0xFF3B82F6),
          border: Color(0xFFE5E7EB),
        ),
    };
  }
}
