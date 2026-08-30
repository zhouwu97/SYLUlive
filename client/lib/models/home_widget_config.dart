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

/// 桌面小组件字号只提供经过布局验证的三个安全档位。
enum HomeWidgetFontSize {
  small,
  standard,
  large;

  String get storageName => name;

  String get label => switch (this) {
        HomeWidgetFontSize.small => '小',
        HomeWidgetFontSize.standard => '标准',
        HomeWidgetFontSize.large => '大',
      };

  static HomeWidgetFontSize fromStorage(String? value) {
    return HomeWidgetFontSize.values.firstWhere(
      (fontSize) => fontSize.storageName == value,
      orElse: () => HomeWidgetFontSize.standard,
    );
  }
}

enum HomeWidgetSize {
  size2x2,
  size4x2;

  String get channelName => switch (this) {
        HomeWidgetSize.size2x2 => '2x2',
        HomeWidgetSize.size4x2 => '4x2',
      };

  String get label => switch (this) {
        HomeWidgetSize.size2x2 => '2×2 紧凑版',
        HomeWidgetSize.size4x2 => '4×2 列表版',
      };
}

class HomeWidgetAppearance {
  const HomeWidgetAppearance({
    required this.kind,
    required this.theme,
    required this.title,
    this.fontSize = HomeWidgetFontSize.standard,
  });

  final HomeWidgetKind kind;
  final HomeWidgetTheme theme;
  final String title;
  final HomeWidgetFontSize fontSize;

  HomeWidgetAppearance copyWith({
    HomeWidgetTheme? theme,
    String? title,
    HomeWidgetFontSize? fontSize,
  }) {
    return HomeWidgetAppearance(
      kind: kind,
      theme: theme ?? this.theme,
      title: title ?? this.title,
      fontSize: fontSize ?? this.fontSize,
    );
  }
}

class HomeWidgetPreferenceKeys {
  const HomeWidgetPreferenceKeys._();

  static const courseTheme = 'widget_course_theme';
  static const examTheme = 'widget_exam_theme';
  static const courseTitle = 'widget_course_title';
  static const examTitle = 'widget_exam_title';
  static const courseFontSize = 'widget_course_font_size';
  static const examFontSize = 'widget_exam_font_size';

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

  static String fontSize(HomeWidgetKind kind) => switch (kind) {
        HomeWidgetKind.course => courseFontSize,
        HomeWidgetKind.exam => examFontSize,
      };
}

/// Flutter 预览与 Android RemoteViews 共用的语义字号角色。
///
/// 这里只描述文字大小，不携带任何布局尺寸，确保切换字号不会改变
/// 小组件结构、条目高度、色条位置和内容顺序。
class HomeWidgetTypography {
  const HomeWidgetTypography({
    required this.title,
    required this.subtitle,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.badge,
    required this.empty,
  });

  final double title;
  final double subtitle;
  final double primary;
  final double secondary;
  final double tertiary;
  final double badge;
  final double empty;

  static HomeWidgetTypography resolve(
    HomeWidgetSize size,
    HomeWidgetFontSize fontSize,
  ) {
    final isWide = size == HomeWidgetSize.size4x2;
    return switch ((isWide, fontSize)) {
      (false, HomeWidgetFontSize.small) => const HomeWidgetTypography(
          title: 12,
          subtitle: 8,
          primary: 10,
          secondary: 8,
          tertiary: 8,
          badge: 7,
          empty: 10,
        ),
      (false, HomeWidgetFontSize.standard) => const HomeWidgetTypography(
          title: 13,
          subtitle: 9,
          primary: 11,
          secondary: 9,
          tertiary: 8,
          badge: 8,
          empty: 11,
        ),
      (false, HomeWidgetFontSize.large) => const HomeWidgetTypography(
          title: 14,
          subtitle: 10,
          primary: 12,
          secondary: 10,
          tertiary: 9,
          badge: 9,
          empty: 12,
        ),
      (true, HomeWidgetFontSize.small) => const HomeWidgetTypography(
          title: 13,
          subtitle: 9,
          primary: 11,
          secondary: 8,
          tertiary: 7,
          badge: 7,
          empty: 11,
        ),
      (true, HomeWidgetFontSize.standard) => const HomeWidgetTypography(
          title: 14,
          subtitle: 10,
          primary: 12,
          secondary: 9,
          tertiary: 8,
          badge: 8,
          empty: 12,
        ),
      (true, HomeWidgetFontSize.large) => const HomeWidgetTypography(
          title: 15,
          subtitle: 11,
          primary: 13,
          secondary: 10,
          tertiary: 9,
          badge: 9,
          empty: 13,
        ),
    };
  }
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
