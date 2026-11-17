import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_theme.dart';
import 'theme_contrast.dart';
import 'theme_manifest.dart';

/// 保存最终值与来源；来源只用于展示和文件留存，不参与重新拼装外观。
class ThemeAppearance {
  const ThemeAppearance(this.data);
  const ThemeAppearance.empty() : data = const {};
  final Map<String, dynamic> data;

  Map<String, dynamic>? group(ThemeGroup group) =>
      data[group.name] as Map<String, dynamic>?;

  ThemeData buildTheme(Brightness brightness) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final colors = group(ThemeGroup.colors)?[mode] as Map<String, dynamic>?;
    final preset = group(ThemeGroup.shape)?['value'] as String? ?? 'standard';
    return AppTheme.build(
      brightness: brightness,
      palette: colors == null
          ? null
          : AppPalette.fromJson(colors['tokens'] as Map<String, dynamic>,
              coursePalette: [
                  for (final hex in colors['coursePalette'] as List)
                    ThemeContrast.parseColor(hex as String)
                ]),
      seedColor: colors == null
          ? AppTheme.primaryColor
          : ThemeContrast.parseColor(colors['seedColor'] as String),
      variant: colors == null
          ? DynamicSchemeVariant.tonalSpot
          : DynamicSchemeVariant.values
              .byName(colors['schemeVariant'] as String),
      shape: AppShape(preset: AppShapePreset.values.byName(preset)),
    );
  }

  ThemeAppearance apply(
      ThemeManifest manifest, Set<ThemeGroup> selected, String directory) {
    final source = {'themeId': manifest.id, 'version': manifest.version};
    final assetPaths = manifest.assets.map((asset) => asset.path).toSet();
    dynamic resolve(dynamic value) {
      if (value is String && assetPaths.contains(value)) {
        return '$directory/$value';
      }
      if (value is Map) {
        return value
            .map((key, child) => MapEntry(key as String, resolve(child)));
      }
      if (value is List) return value.map(resolve).toList();
      return value;
    }

    final next = <String, dynamic>{...data};
    final light = manifest.data['light'] as Map<String, dynamic>;
    final dark = manifest.data['dark'] as Map<String, dynamic>;
    for (final group in selected) {
      switch (group) {
        case ThemeGroup.colors:
          next['colors'] = {
            'source': source,
            for (final mode in ['light', 'dark'])
              mode: <String, dynamic>{
                for (final field in [
                  'seedColor',
                  'schemeVariant',
                  'tokens',
                  'coursePalette'
                ])
                  field: (manifest.data[mode] as Map)[field],
              }
          };
        case ThemeGroup.shape:
          next['shape'] = {
            'source': source,
            'value': manifest.data['shape'] ?? 'standard'
          };
        case ThemeGroup.wallpapers:
          next['wallpapers'] = {
            'source': source,
            'light': resolve(light['wallpapers'] ?? {}),
            'dark': resolve(dark['wallpapers'] ?? {})
          };
        case ThemeGroup.material:
          next['material'] = {
            'source': source,
            for (final mode in ['light', 'dark'])
              mode: <String, dynamic>{
                'componentOpacity':
                    manifest.data[mode]['componentOpacity'] ?? 1.0,
                'frostedGlass': manifest.data[mode]['frostedGlass'] ??
                    {'enabled': false, 'strength': 0.0},
                if (manifest.data[mode]['cardStyle'] != null)
                  'cardStyle': manifest.data[mode]['cardStyle'],
              }
          };
        case ThemeGroup.navigation:
          next['navigation'] = {
            'source': source,
            ...resolve(manifest.data['bottomNav']) as Map<String, dynamic>,
            if (this.group(ThemeGroup.navigation)?['motion'] != null)
              'motion': this.group(ThemeGroup.navigation)!['motion']
          };
        case ThemeGroup.layout:
        case ThemeGroup.decoration:
        case ThemeGroup.font:
        case ThemeGroup.widgets:
        case ThemeGroup.launcherIcon:
          break;
      }
    }
    return ThemeAppearance(next);
  }

  ThemeAppearance without(ThemeGroup group) =>
      ThemeAppearance({...data}..remove(group.name));

  ThemeAppearance patchMaterial(
      Brightness brightness, Map<String, dynamic> patch) {
    final material = group(ThemeGroup.material);
    if (material == null) return this;
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    return ThemeAppearance({
      ...data,
      'material': {
        ...material,
        'source': null,
        mode: <String, dynamic>{...material[mode] as Map, ...patch},
      }
    });
  }

  ThemeAppearance resetNavigationStyle() {
    final navigation = group(ThemeGroup.navigation);
    if (navigation == null) return this;
    return ThemeAppearance({
      ...data,
      'navigation': {
        ...navigation,
        'source': null,
        'style': null,
        'motion': null,
      }
    });
  }

  ThemeAppearance patchWallpaperBlur(
      Brightness brightness, int tab, double blur) {
    final wallpapers = group(ThemeGroup.wallpapers);
    if (wallpapers == null) return this;
    final legacy = wallpapers['legacy'] as Map?;
    if (legacy != null) {
      return ThemeAppearance({
        ...data,
        'wallpapers': {
          ...wallpapers,
          'source': null,
          'legacy': {...legacy, 'blur': blur},
        }
      });
    }
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final slots = wallpapers[mode] as Map;
    final selected =
        switch (tab) { 0 => 'home', 2 => 'schedule', 4 => 'me', _ => 'global' };
    final slot = slots[selected] == null ? 'global' : selected;
    if (slots[slot] == null) return this;
    return ThemeAppearance({
      ...data,
      'wallpapers': {
        ...wallpapers,
        'source': null,
        mode: <String, dynamic>{
          ...slots,
          slot: {...slots[slot] as Map, 'blur': blur}
        },
      }
    });
  }

  ThemeAppearance replacePath(String old, String replacement) {
    dynamic visit(dynamic value) {
      if (value == old) return replacement;
      if (value is Map) {
        return value.map((key, child) => MapEntry(key as String, visit(child)));
      }
      if (value is List) return value.map(visit).toList();
      return value;
    }

    return ThemeAppearance(visit(data) as Map<String, dynamic>);
  }

  Iterable<String> get paths sync* {
    Iterable<String> visit(dynamic value) sync* {
      if (value is String) yield value;
      if (value is Map) {
        for (final child in value.values) {
          yield* visit(child);
        }
      }
      if (value is List) {
        for (final child in value) {
          yield* visit(child);
        }
      }
    }

    yield* visit(data);
  }

  Iterable<(String, int)> get versions sync* {
    for (final value in data.values) {
      if (value is Map && value['source'] != null) {
        final source = value['source'] as Map;
        yield (source['themeId'] as String, source['version'] as int);
      }
    }
  }
}
