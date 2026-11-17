import 'package:flutter/material.dart';

import '../../theme/app_palette.dart';
import '../../theme/app_theme.dart';
import 'theme_contrast.dart';
import 'theme_font_registry.dart';
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
    final fontFamily =
        ThemeFontRegistry.resolvedFamilyFor(group(ThemeGroup.font));
    final materialGroup = group(ThemeGroup.material);
    Map? rawCardStyle;
    if (materialGroup != null && materialGroup['legacy'] != true) {
      final modeMat = materialGroup[mode];
      if (modeMat is Map && modeMat['cardStyle'] is Map) {
        rawCardStyle = modeMat['cardStyle'] as Map;
      }
    }
    return AppTheme.build(
      brightness: brightness,
      fontFamily: fontFamily,
      rawCardStyle: rawCardStyle,
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
    final source = {
      'themeId': manifest.id,
      'version': manifest.version,
      'name': manifest.name,
    };
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
        case ThemeGroup.font:
          final fontData = manifest.data['font'];
          if (fontData != null) {
            next['font'] = {
              'source': source,
              ...resolve(fontData) as Map<String, dynamic>,
            };
          }
        case ThemeGroup.widgets:
          next['widgets'] = {
            'source': source,
          };
        case ThemeGroup.launcherIcon:
          final launcherData = manifest.data['launcherIcon'];
          if (launcherData != null) {
            next['launcherIcon'] = {
              'source': source,
              ...resolve(launcherData) as Map<String, dynamic>,
            };
          }
        case ThemeGroup.layout:
          final layoutData = manifest.data['layout'] as Map?;
          if (layoutData != null && layoutData.isNotEmpty) {
            next['layout'] = {
              'source': source,
              'value': {
                for (final entry in layoutData.entries)
                  if (entry.value is Map)
                    entry.key as String:
                        Map<String, dynamic>.from(entry.value as Map),
              },
            };
          } else {
            next.remove('layout');
          }
        case ThemeGroup.decoration:
          next['decoration'] = {
            'source': source,
            'light': resolve(light['decorations'] ?? {}),
            'dark': resolve(dark['decorations'] ?? {}),
          };
      }
    }
    return ThemeAppearance(next);
  }

  ThemeAppearance without(ThemeGroup group) =>
      ThemeAppearance({...data}..remove(group.name));

  ThemeAppearance patchCardStyle(
    Brightness brightness,
    Map<String, dynamic>? cardStyle, {
    required double fallbackOpacity,
    required bool fallbackFrosted,
    required double fallbackStrength,
  }) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final existing = group(ThemeGroup.material);
    final base = (existing != null && existing['legacy'] != true)
        ? existing
        : <String, dynamic>{
            'source': null,
            for (final m in const ['light', 'dark'])
              m: <String, dynamic>{
                'componentOpacity': fallbackOpacity,
                'frostedGlass': {
                  'enabled': fallbackFrosted,
                  'strength': fallbackStrength,
                },
              },
          };
    final nextMode = Map<String, dynamic>.from(base[mode] as Map);
    if (cardStyle == null || cardStyle.isEmpty) {
      nextMode.remove('cardStyle');
    } else {
      nextMode['cardStyle'] = Map<String, dynamic>.from(cardStyle);
    }
    return ThemeAppearance({
      ...data,
      'material': {
        ...base,
        'source': null,
        mode: nextMode,
      },
    });
  }

  ThemeAppearance patchHeaderLayout(
    String slot,
    Map<String, dynamic>? headerLayout,
  ) {
    final currentValue = Map<String, dynamic>.from(
      (group(ThemeGroup.layout)?['value'] as Map?) ?? const {},
    );
    if (headerLayout == null || headerLayout.isEmpty) {
      currentValue.remove(slot);
    } else {
      currentValue[slot] = Map<String, dynamic>.from(headerLayout);
    }
    if (currentValue.isEmpty) {
      return without(ThemeGroup.layout);
    }
    return ThemeAppearance({
      ...data,
      'layout': {
        'source': null,
        'value': currentValue,
      },
    });
  }

  ThemeAppearance patchHeaderDecoration(
    Brightness brightness,
    String slot,
    Map<String, dynamic>? slotDecoration,
  ) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    final existing = group(ThemeGroup.decoration);
    final lightMap = Map<String, dynamic>.from(
      (existing?['light'] as Map?) ?? const {},
    );
    final darkMap = Map<String, dynamic>.from(
      (existing?['dark'] as Map?) ?? const {},
    );
    final target = mode == 'dark' ? darkMap : lightMap;
    final hasContent = slotDecoration != null &&
        (slotDecoration['background'] != null ||
            ((slotDecoration['stickers'] as List?)?.isNotEmpty ?? false));
    if (!hasContent) {
      target.remove(slot);
    } else {
      target[slot] = Map<String, dynamic>.from(slotDecoration);
    }
    final anyLight = lightMap.values.any((v) => v != null);
    final anyDark = darkMap.values.any((v) => v != null);
    if (!anyLight && !anyDark) {
      return without(ThemeGroup.decoration);
    }
    return ThemeAppearance({
      ...data,
      'decoration': {
        'source': null,
        'light': lightMap,
        'dark': darkMap,
      },
    });
  }

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

  List<(ThemeGroup, String)> get activeGroupSources {
    final items = <(ThemeGroup, String)>[];
    for (final item in ThemeGroup.values) {
      final entry = group(item);
      if (entry == null) continue;
      if (entry['legacy'] != null) continue;
      final source = entry['source'] as Map?;
      if (source != null) {
        final title = (source['name'] as String?)?.trim();
        final label = (title != null && title.isNotEmpty)
            ? '$title v${source['version']}'
            : '${source['themeId']} v${source['version']}';
        items.add((item, label));
      } else {
        items.add((item, '手动调整'));
      }
    }
    return items;
  }

  String? get singleThemeName {
    final sources = <String>{};
    for (final entry in data.values) {
      if (entry is! Map || entry['legacy'] != null) continue;
      final source = entry['source'] as Map?;
      if (source == null) return null;
      final name = (source['name'] as String?)?.trim();
      if (name == null || name.isEmpty) return null;
      sources.add(name);
    }
    return sources.length == 1 ? sources.single : null;
  }

  String summaryLabel({String? manualSummary}) {
    final items = activeGroupSources;
    if (items.isEmpty) return manualSummary ?? '默认外观';
    final uniqueSources = items.map((e) => e.$2).toSet();
    if (uniqueSources.length == 1 && uniqueSources.single != '手动调整') {
      final labels = items.map((e) => e.$1.label).join('、');
      return '${uniqueSources.single} · $labels';
    }
    final detail = items.map((e) => '${e.$1.label}（${e.$2}）').join(' · ');
    return '混搭外观 · $detail';
  }
}
