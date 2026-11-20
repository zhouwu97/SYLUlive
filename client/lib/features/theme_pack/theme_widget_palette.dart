import 'dart:convert';
import 'dart:ui';

import '../../models/home_widget_config.dart';
import '../../theme/app_palette.dart';
import 'theme_appearance.dart';
import 'theme_contrast.dart';
import 'theme_manifest.dart';

/// 桌面小部件跟随 App 主题的配色换算与课程色板取色（契约 3.1）。
abstract final class ThemeWidgetPalette {
  static const storageKey = 'widget_app_palette_v1';
  static const frostedAlphaByte = 209; // round(0.82 * 255)

  static String formatArgbHex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  static String formatRgbHex(Color color) {
    final rgb = color.toARGB32() & 0x00FFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  static Map<String, String> variantFromPalette(
    AppPalette palette, {
    bool frostedGlass = false,
  }) {
    final bg = frostedGlass
        ? palette.card.withAlpha(frostedAlphaByte)
        : palette.card.withAlpha(0xFF);
    return {
      'background': formatArgbHex(bg),
      'primaryText': formatArgbHex(palette.textPrimary),
      'secondaryText': formatArgbHex(palette.textSecondary),
      'mutedText': formatArgbHex(palette.textTertiary),
      'accent': formatArgbHex(palette.primary),
      'divider': formatArgbHex(palette.divider),
    };
  }

  static AppPalette paletteFromAppearance(
    ThemeAppearance appearance,
    Brightness brightness,
  ) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final colors =
        appearance.group(ThemeGroup.colors)?[mode] as Map<String, dynamic>?;
    if (colors == null) {
      return AppPalette.defaults(brightness);
    }
    return AppPalette.fromJson(
      colors['tokens'] as Map<String, dynamic>,
      coursePalette: [
        for (final hex in colors['coursePalette'] as List)
          ThemeContrast.parseColor(hex as String),
      ],
    );
  }

  static Map<String, dynamic> buildPayload(ThemeAppearance appearance) {
    return {
      'light': variantFromPalette(
        paletteFromAppearance(appearance, Brightness.light),
      ),
      'dark': variantFromPalette(
        paletteFromAppearance(appearance, Brightness.dark),
      ),
    };
  }

  static String encodePayload(ThemeAppearance appearance) =>
      jsonEncode(buildPayload(appearance));

  static HomeWidgetThemePalette? resolveStored(
    String? rawJson, {
    required Brightness systemBrightness,
    bool frostedGlass = false,
  }) {
    if (rawJson == null || rawJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return null;
      final mode = systemBrightness == Brightness.dark ? 'dark' : 'light';
      final variant = decoded[mode];
      if (variant is! Map) return null;
      Color parse(String key) =>
          ThemeContrast.parseColor(variant[key] as String);
      final baseBg = parse('background');
      final bg = frostedGlass
          ? baseBg.withAlpha(frostedAlphaByte)
          : baseBg.withAlpha(0xFF);
      return HomeWidgetThemePalette(
        background: bg,
        primaryText: parse('primaryText'),
        secondaryText: parse('secondaryText'),
        mutedText: parse('mutedText'),
        accent: parse('accent'),
        border: parse('divider'),
      );
    } catch (_) {
      return null;
    }
  }

  static List<Color> coursePaletteFromAppearance(
    ThemeAppearance appearance, {
    Brightness brightness = Brightness.light,
  }) =>
      paletteFromAppearance(appearance, brightness).coursePalette;

  static int courseColorIndex(
    String name, {
    required int paletteLength,
    String? courseCode,
    String? location,
  }) {
    var input = name;
    if (name.isEmpty) {
      input = '${courseCode ?? ''}_${location ?? ''}';
    }
    if (input.isEmpty || paletteLength <= 0) return 0;
    var hash = 0;
    for (var i = 0; i < input.length; i++) {
      hash += input.codeUnitAt(i);
    }
    return hash % paletteLength;
  }

  static String resolveCourseHex(
    String name, {
    required List<Color> palette,
    String? courseCode,
    String? location,
  }) {
    if (palette.isEmpty) return '#448AFF';
    final idx = courseColorIndex(
      name,
      paletteLength: palette.length,
      courseCode: courseCode,
      location: location,
    );
    return formatRgbHex(palette[idx]);
  }
}
