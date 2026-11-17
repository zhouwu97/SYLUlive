import 'package:flutter/material.dart';

import 'app_radius.dart';

/// 主题包中的语义颜色；字段名与格式契约一致。
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.primary,
    required this.onPrimary,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceMuted,
    required this.card,
    required this.cardBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textDisabled,
    required this.divider,
    required this.outline,
    required this.inputFill,
    required this.inputFillFocused,
    required this.searchFill,
    required this.tagBackground,
    required this.tagText,
    required this.navBackground,
    required this.navSelected,
    required this.navUnselected,
    required this.appBarBackground,
    required this.appBarForeground,
    required this.bubbleIncoming,
    required this.bubbleIncomingText,
    required this.bubbleOutgoing,
    required this.bubbleOutgoingText,
    required this.feedSectionSurface,
    required this.feedFeaturedSurface,
    required this.feedFeaturedText,
    required this.courseCardText,
    required this.timetableGrid,
    required this.timetableToday,
    required this.coursePalette,
  });

  final Color primary;
  final Color onPrimary;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceMuted;
  final Color card;
  final Color cardBorder;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textDisabled;
  final Color divider;
  final Color outline;
  final Color inputFill;
  final Color inputFillFocused;
  final Color searchFill;
  final Color tagBackground;
  final Color tagText;
  final Color navBackground;
  final Color navSelected;
  final Color navUnselected;
  final Color appBarBackground;
  final Color appBarForeground;
  final Color bubbleIncoming;
  final Color bubbleIncomingText;
  final Color bubbleOutgoing;
  final Color bubbleOutgoingText;
  final Color feedSectionSurface;
  final Color feedFeaturedSurface;
  final Color feedFeaturedText;
  final Color courseCardText;
  final Color timetableGrid;
  final Color timetableToday;
  final List<Color> coursePalette;

  factory AppPalette.defaults(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  Map<String, Color> get tokenColors => {
        'primary': primary,
        'onPrimary': onPrimary,
        'primaryContainer': primaryContainer,
        'onPrimaryContainer': onPrimaryContainer,
        'background': background,
        'surface': surface,
        'surfaceElevated': surfaceElevated,
        'surfaceMuted': surfaceMuted,
        'card': card,
        'cardBorder': cardBorder,
        'textPrimary': textPrimary,
        'textSecondary': textSecondary,
        'textTertiary': textTertiary,
        'textDisabled': textDisabled,
        'divider': divider,
        'outline': outline,
        'inputFill': inputFill,
        'inputFillFocused': inputFillFocused,
        'searchFill': searchFill,
        'tagBackground': tagBackground,
        'tagText': tagText,
        'navBackground': navBackground,
        'navSelected': navSelected,
        'navUnselected': navUnselected,
        'appBarBackground': appBarBackground,
        'appBarForeground': appBarForeground,
        'bubbleIncoming': bubbleIncoming,
        'bubbleIncomingText': bubbleIncomingText,
        'bubbleOutgoing': bubbleOutgoing,
        'bubbleOutgoingText': bubbleOutgoingText,
        'feedSectionSurface': feedSectionSurface,
        'feedFeaturedSurface': feedFeaturedSurface,
        'feedFeaturedText': feedFeaturedText,
        'courseCardText': courseCardText,
        'timetableGrid': timetableGrid,
        'timetableToday': timetableToday,
      };

  Map<String, String> toJson() => tokenColors.map((name, color) {
        final hex =
            color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase();
        return MapEntry(
            name, '#${hex.startsWith('FF') ? hex.substring(2) : hex}');
      });

  static const _light = AppPalette(
    primary: Color(0xFF147C72),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFEAF6F3),
    onPrimaryContainer: Color(0xFF0F635B),
    background: Color(0xFFFFFAF4),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF2F3F1),
    card: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFE2EFEA),
    textPrimary: Color(0xFF1F2328),
    textSecondary: Color(0xFF747B82),
    textTertiary: Color(0xFF9AA1A1),
    textDisabled: Color(0xFFB8BDBA),
    divider: Color(0xFFE8EEE9),
    outline: Color(0xFFE2EFEA),
    inputFill: Color(0xFFF2F3F1),
    inputFillFocused: Color(0xFFEFF4F1),
    searchFill: Color(0xFFF1F2F0),
    tagBackground: Color(0xFFEEF2F0),
    tagText: Color(0xFF147C72),
    navBackground: Color(0x9EEDF0F5),
    navSelected: Color(0xFF1765DA),
    navUnselected: Color(0xFF4B525E),
    appBarBackground: Color(0xFFF4FBF8),
    appBarForeground: Color(0xFF161D1C),
    bubbleIncoming: Color(0xFFF0F1EF),
    bubbleIncomingText: Color(0xFF1F2328),
    bubbleOutgoing: Color(0xFF76C4FF),
    bubbleOutgoingText: Color(0xFF1F2328),
    feedSectionSurface: Color(0xFFE8F5F1),
    feedFeaturedSurface: Color(0xFFFFF3E0),
    feedFeaturedText: Color(0xFFD97706),
    courseCardText: Color(0xFF1F2328),
    timetableGrid: Color(0x0D000000),
    timetableToday: Color(0x00000000),
    coursePalette: [
      Color(0xFF448AFF),
      Color(0xFF00C853),
      Color(0xFF9C27B0),
      Color(0xFFFF5252),
      Color(0xFFFF9800),
    ],
  );

  static const _dark = AppPalette(
    primary: Color(0xFF7ED6C5),
    onPrimary: Color(0xFF0F2622),
    primaryContainer: Color(0xFF162B28),
    onPrimaryContainer: Color(0xFF7ED6C5),
    background: Color(0xFF111315),
    surface: Color(0xFF1A1D1F),
    surfaceElevated: Color(0xFF232729),
    surfaceMuted: Color(0xFF24282A),
    card: Color(0xFF1A1D1F),
    cardBorder: Color(0xFF303638),
    textPrimary: Color(0xFFF2F4F3),
    textSecondary: Color(0xFFA7AFAB),
    textTertiary: Color(0xFF8E9894),
    textDisabled: Color(0xFF5A615D),
    divider: Color(0xFF252A2C),
    outline: Color(0xFF303638),
    inputFill: Color(0xFF24282A),
    inputFillFocused: Color(0xFF2B3033),
    searchFill: Color(0xFF24282A),
    tagBackground: Color(0xFF282D30),
    tagText: Color(0xFF90D5C7),
    navBackground: Color(0xB8252A32),
    navSelected: Color(0xFF84BAFF),
    navUnselected: Color(0xFFD1D5DB),
    appBarBackground: Color(0xFF0E1513),
    appBarForeground: Color(0xFFDDE4E1),
    bubbleIncoming: Color(0xFF262A2C),
    bubbleIncomingText: Color(0xFFF2F4F3),
    bubbleOutgoing: Color(0xFF80C4FC),
    bubbleOutgoingText: Color(0xFF111315),
    feedSectionSurface: Color(0xFF162B28),
    feedFeaturedSurface: Color(0xFF3A2A18),
    feedFeaturedText: Color(0xFFF2B15A),
    courseCardText: Color(0xFFFFFFFF),
    timetableGrid: Color(0x33FFFFFF),
    timetableToday: Color(0x00000000),
    coursePalette: [
      Color(0xFF448AFF),
      Color(0xFF00C853),
      Color(0xFF9C27B0),
      Color(0xFFFF5252),
      Color(0xFFFF9800),
    ],
  );

  /// manifest 的类型与范围由导入边界校验，这里只转换已校验的值。
  factory AppPalette.fromJson(
    Map<String, dynamic> tokens, {
    required List<Color> coursePalette,
  }) {
    Color color(String key) {
      final hex = (tokens[key] as String).substring(1);
      return Color(int.parse(hex.length == 6 ? 'FF$hex' : hex, radix: 16));
    }

    return AppPalette(
      primary: color('primary'),
      onPrimary: color('onPrimary'),
      primaryContainer: color('primaryContainer'),
      onPrimaryContainer: color('onPrimaryContainer'),
      background: color('background'),
      surface: color('surface'),
      surfaceElevated: color('surfaceElevated'),
      surfaceMuted: color('surfaceMuted'),
      card: color('card'),
      cardBorder: color('cardBorder'),
      textPrimary: color('textPrimary'),
      textSecondary: color('textSecondary'),
      textTertiary: color('textTertiary'),
      textDisabled: color('textDisabled'),
      divider: color('divider'),
      outline: color('outline'),
      inputFill: color('inputFill'),
      inputFillFocused: color('inputFillFocused'),
      searchFill: color('searchFill'),
      tagBackground: color('tagBackground'),
      tagText: color('tagText'),
      navBackground: color('navBackground'),
      navSelected: color('navSelected'),
      navUnselected: color('navUnselected'),
      appBarBackground: color('appBarBackground'),
      appBarForeground: color('appBarForeground'),
      bubbleIncoming: color('bubbleIncoming'),
      bubbleIncomingText: color('bubbleIncomingText'),
      bubbleOutgoing: color('bubbleOutgoing'),
      bubbleOutgoingText: color('bubbleOutgoingText'),
      feedSectionSurface: color('feedSectionSurface'),
      feedFeaturedSurface: color('feedFeaturedSurface'),
      feedFeaturedText: color('feedFeaturedText'),
      courseCardText: color('courseCardText'),
      timetableGrid: color('timetableGrid'),
      timetableToday: color('timetableToday'),
      coursePalette: List.unmodifiable(coursePalette),
    );
  }

  @override
  AppPalette copyWith({
    Color? primary,
    Color? onPrimary,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? background,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceMuted,
    Color? card,
    Color? cardBorder,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textDisabled,
    Color? divider,
    Color? outline,
    Color? inputFill,
    Color? inputFillFocused,
    Color? searchFill,
    Color? tagBackground,
    Color? tagText,
    Color? navBackground,
    Color? navSelected,
    Color? navUnselected,
    Color? appBarBackground,
    Color? appBarForeground,
    Color? bubbleIncoming,
    Color? bubbleIncomingText,
    Color? bubbleOutgoing,
    Color? bubbleOutgoingText,
    Color? feedSectionSurface,
    Color? feedFeaturedSurface,
    Color? feedFeaturedText,
    Color? courseCardText,
    Color? timetableGrid,
    Color? timetableToday,
    List<Color>? coursePalette,
  }) =>
      AppPalette(
        primary: primary ?? this.primary,
        onPrimary: onPrimary ?? this.onPrimary,
        primaryContainer: primaryContainer ?? this.primaryContainer,
        onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
        background: background ?? this.background,
        surface: surface ?? this.surface,
        surfaceElevated: surfaceElevated ?? this.surfaceElevated,
        surfaceMuted: surfaceMuted ?? this.surfaceMuted,
        card: card ?? this.card,
        cardBorder: cardBorder ?? this.cardBorder,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
        textTertiary: textTertiary ?? this.textTertiary,
        textDisabled: textDisabled ?? this.textDisabled,
        divider: divider ?? this.divider,
        outline: outline ?? this.outline,
        inputFill: inputFill ?? this.inputFill,
        inputFillFocused: inputFillFocused ?? this.inputFillFocused,
        searchFill: searchFill ?? this.searchFill,
        tagBackground: tagBackground ?? this.tagBackground,
        tagText: tagText ?? this.tagText,
        navBackground: navBackground ?? this.navBackground,
        navSelected: navSelected ?? this.navSelected,
        navUnselected: navUnselected ?? this.navUnselected,
        appBarBackground: appBarBackground ?? this.appBarBackground,
        appBarForeground: appBarForeground ?? this.appBarForeground,
        bubbleIncoming: bubbleIncoming ?? this.bubbleIncoming,
        bubbleIncomingText: bubbleIncomingText ?? this.bubbleIncomingText,
        bubbleOutgoing: bubbleOutgoing ?? this.bubbleOutgoing,
        bubbleOutgoingText: bubbleOutgoingText ?? this.bubbleOutgoingText,
        feedSectionSurface: feedSectionSurface ?? this.feedSectionSurface,
        feedFeaturedSurface: feedFeaturedSurface ?? this.feedFeaturedSurface,
        feedFeaturedText: feedFeaturedText ?? this.feedFeaturedText,
        courseCardText: courseCardText ?? this.courseCardText,
        timetableGrid: timetableGrid ?? this.timetableGrid,
        timetableToday: timetableToday ?? this.timetableToday,
        coursePalette: coursePalette == null
            ? this.coursePalette
            : List.unmodifiable(coursePalette),
      );

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      primaryContainer:
          Color.lerp(primaryContainer, other.primaryContainer, t)!,
      onPrimaryContainer:
          Color.lerp(onPrimaryContainer, other.onPrimaryContainer, t)!,
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      card: Color.lerp(card, other.card, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      textDisabled: Color.lerp(textDisabled, other.textDisabled, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      inputFill: Color.lerp(inputFill, other.inputFill, t)!,
      inputFillFocused:
          Color.lerp(inputFillFocused, other.inputFillFocused, t)!,
      searchFill: Color.lerp(searchFill, other.searchFill, t)!,
      tagBackground: Color.lerp(tagBackground, other.tagBackground, t)!,
      tagText: Color.lerp(tagText, other.tagText, t)!,
      navBackground: Color.lerp(navBackground, other.navBackground, t)!,
      navSelected: Color.lerp(navSelected, other.navSelected, t)!,
      navUnselected: Color.lerp(navUnselected, other.navUnselected, t)!,
      appBarBackground:
          Color.lerp(appBarBackground, other.appBarBackground, t)!,
      appBarForeground:
          Color.lerp(appBarForeground, other.appBarForeground, t)!,
      bubbleIncoming: Color.lerp(bubbleIncoming, other.bubbleIncoming, t)!,
      bubbleIncomingText:
          Color.lerp(bubbleIncomingText, other.bubbleIncomingText, t)!,
      bubbleOutgoing: Color.lerp(bubbleOutgoing, other.bubbleOutgoing, t)!,
      bubbleOutgoingText:
          Color.lerp(bubbleOutgoingText, other.bubbleOutgoingText, t)!,
      feedSectionSurface:
          Color.lerp(feedSectionSurface, other.feedSectionSurface, t)!,
      feedFeaturedSurface:
          Color.lerp(feedFeaturedSurface, other.feedFeaturedSurface, t)!,
      feedFeaturedText:
          Color.lerp(feedFeaturedText, other.feedFeaturedText, t)!,
      courseCardText: Color.lerp(courseCardText, other.courseCardText, t)!,
      timetableGrid: Color.lerp(timetableGrid, other.timetableGrid, t)!,
      timetableToday: Color.lerp(timetableToday, other.timetableToday, t)!,
      coursePalette: t < 0.5 ? coursePalette : other.coursePalette,
    );
  }
}

enum AppShapePreset {
  compact(0.75),
  standard(1.0),
  rounded(1.35);

  const AppShapePreset(this.scale);
  final double scale;
}

class AppShape extends ThemeExtension<AppShape> {
  const AppShape({this.preset = AppShapePreset.standard});

  final AppShapePreset preset;

  static AppShape of(BuildContext context) =>
      Theme.of(context).extension<AppShape>() ?? const AppShape();

  double get sm => AppRadius.sm * preset.scale;
  double get md => AppRadius.md * preset.scale;
  double get lg => AppRadius.lg * preset.scale;
  double get sheet => AppRadius.sheet * preset.scale;
  double get pill => AppRadius.pill;

  @override
  AppShape copyWith({AppShapePreset? preset}) =>
      AppShape(preset: preset ?? this.preset);

  @override
  AppShape lerp(covariant AppShape? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

class AppCardStyle extends ThemeExtension<AppCardStyle> {
  const AppCardStyle({
    this.borderWidth,
    this.shadow,
  });

  final double? borderWidth;
  final String? shadow;

  bool get hasOverrides => borderWidth != null || shadow != null;

  static AppCardStyle of(BuildContext context) =>
      Theme.of(context).extension<AppCardStyle>() ?? const AppCardStyle();

  factory AppCardStyle.fromJson(Map? raw) {
    if (raw == null || raw.isEmpty) return const AppCardStyle();
    final bw = (raw['borderWidth'] as num?)?.toDouble();
    final sh = raw['shadow'] as String?;
    return AppCardStyle(
      borderWidth: (bw != null && bw.isFinite) ? bw.clamp(0.0, 2.0) : null,
      shadow: const {'none', 'soft', 'medium'}.contains(sh) ? sh : null,
    );
  }

  BoxBorder? resolveBoxBorder(Color borderColor) {
    final bw = borderWidth;
    if (bw == null) return null;
    if (bw <= 0) return const Border();
    return Border.all(color: borderColor, width: bw);
  }

  BorderSide? resolveBorderSide(Color borderColor) {
    final bw = borderWidth;
    if (bw == null) return null;
    if (bw <= 0) return BorderSide.none;
    return BorderSide(color: borderColor, width: bw);
  }

  List<BoxShadow>? resolveBoxShadows(bool isDark) {
    final sh = shadow;
    if (sh == null) return null;
    return switch (sh) {
      'none' => const <BoxShadow>[],
      'soft' => [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.08),
            offset: const Offset(0, 2),
            blurRadius: 8,
            spreadRadius: 0,
          ),
        ],
      'medium' => [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.12),
            offset: const Offset(0, 4),
            blurRadius: 16,
            spreadRadius: 0,
          ),
        ],
      _ => null,
    };
  }

  @override
  AppCardStyle copyWith({
    double? borderWidth,
    String? shadow,
  }) =>
      AppCardStyle(
        borderWidth: borderWidth ?? this.borderWidth,
        shadow: shadow ?? this.shadow,
      );

  @override
  AppCardStyle lerp(covariant AppCardStyle? other, double t) =>
      other == null || t < 0.5 ? this : other;
}
