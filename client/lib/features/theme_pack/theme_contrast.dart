import 'dart:math' as math;
import 'dart:ui' show Brightness;
import 'package:flutter/painting.dart';

import '../../theme/app_palette.dart';
import 'theme_manifest.dart';

class ThemeContrastIssue {
  const ThemeContrastIssue(this.brightness, this.foreground, this.background,
      this.ratio, this.minimum);
  final Brightness brightness;
  final String foreground;
  final String background;
  final double ratio;
  final double minimum;
}

abstract final class ThemeContrast {
  static double ratio(Color foreground, Color background) {
    final a = foreground.computeLuminance();
    final b = background.computeLuminance();
    return (math.max(a, b) + .05) / (math.min(a, b) + .05);
  }

  static List<ThemeContrastIssue> check(ThemeManifest manifest) {
    final issues = <ThemeContrastIssue>[];
    for (final brightness in Brightness.values) {
      final variant = manifest.variant(brightness);
      final palette = AppPalette.fromJson(
          variant['tokens'] as Map<String, dynamic>,
          coursePalette: [
            for (final hex in variant['coursePalette'] as List)
              parseColor(hex as String)
          ]);
      final colors = palette.tokenColors;
      void compare(String foreground, String background, double threshold,
          {Color? composed}) {
        final base = composed ??
            Color.alphaBlend(colors[background]!, palette.background);
        final front = Color.alphaBlend(colors[foreground]!, base);
        final result = ratio(front, base);
        if (result < threshold) {
          issues.add(ThemeContrastIssue(
              brightness, foreground, background, result, threshold));
        }
      }

      compare('textPrimary', 'background', 4.5);
      compare('textPrimary', 'card', 4.5);
      compare('textSecondary', 'card', 4.5);
      compare('onPrimary', 'primary', 4.5);
      compare('tagText', 'tagBackground', 4.5);
      compare('appBarForeground', 'appBarBackground', 4.5);
      compare('bubbleOutgoingText', 'bubbleOutgoing', 4.5);
      compare('navSelected', 'navBackground', 3);
      compare('navUnselected', 'navBackground', 3);
      for (var i = 0; i < palette.coursePalette.length; i++) {
        compare('courseCardText', 'coursePalette[$i]', 4.5,
            composed: Color.alphaBlend(
                palette.coursePalette[i].withValues(alpha: .45),
                palette.background));
      }
    }
    return issues;
  }

  static Color parseColor(String value) {
    final hex = value.substring(1);
    return Color(int.parse(hex.length == 6 ? 'FF$hex' : hex, radix: 16));
  }
}
