import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/theme_provider.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_theme_tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/global_background_wrapper.dart';
import 'launcher_icon_service.dart';
import 'theme_appearance.dart';
import 'theme_appearance_exporter.dart';
import 'theme_contrast.dart';
import 'theme_font_registry.dart';
import 'theme_layout_decoration_screen.dart';
import 'theme_manifest.dart';
import 'theme_pack_codec.dart';
import 'theme_pack_store.dart';
import 'theme_presentation.dart';
import 'theme_resolver.dart';
import 'theme_section.dart';
import 'theme_submission_screen.dart';
import 'theme_workshop_samples.dart';

enum WorkshopTab {
  colors('配色'),
  courses('课表'),
  wallpapers('壁纸'),
  material('材质'),
  layout('布局'),
  decoration('装饰'),
  icons('图标'),
  font('字体'),
  launcherIcon('桌面图标'),
  widgets('小部件'),
  packages('主题包');

  const WorkshopTab(this.label);
  final String label;
}

enum _WorkshopCategory {
  colors(
      '颜色', Icons.colorize_outlined, [WorkshopTab.colors, WorkshopTab.courses]),
  wallpapers('背景', Icons.wallpaper_outlined, [WorkshopTab.wallpapers]),
  cards('卡片与页头', Icons.dashboard_customize_outlined,
      [WorkshopTab.material, WorkshopTab.layout, WorkshopTab.decoration]),
  navigation('底栏', Icons.space_bar_rounded, [WorkshopTab.icons]),
  typography('图标与字体', Icons.text_fields_rounded,
      [WorkshopTab.font, WorkshopTab.launcherIcon, WorkshopTab.widgets]),
  packages('主题包', Icons.inventory_2_outlined, [WorkshopTab.packages]);

  const _WorkshopCategory(this.label, this.icon, this.tabs);
  final String label;
  final IconData icon;
  final List<WorkshopTab> tabs;
}

class ThemeWorkshopContrastException implements Exception {
  const ThemeWorkshopContrastException(this.issues);
  final List<ThemeContrastIssue> issues;
}

class WorkshopVariantDraft {
  WorkshopVariantDraft({
    required this.seedColor,
    this.schemeVariant = 'tonalSpot',
    Map<String, String>? overrides,
    required List<String> coursePalette,
    Map<String, Map<String, dynamic>?>? wallpapers,
    this.componentOpacity = 1.0,
    this.frostedEnabled = false,
    this.frostedStrength = 0.0,
    this.cardStyle,
    Map<String, Map<String, dynamic>?>? decorations,
  })  : overrides = Map<String, String>.from(overrides ?? const {}),
        coursePalette = List<String>.from(coursePalette),
        wallpapers = Map<String, Map<String, dynamic>?>.from(
          wallpapers ?? const {},
        ),
        decorations = Map<String, Map<String, dynamic>?>.from(
          decorations ?? const {},
        );

  String seedColor;
  String schemeVariant;
  Map<String, String> overrides;
  List<String> coursePalette;
  Map<String, Map<String, dynamic>?> wallpapers;
  double componentOpacity;
  bool frostedEnabled;
  double frostedStrength;
  Map<String, dynamic>? cardStyle;
  Map<String, Map<String, dynamic>?> decorations;

  Map<String, String> effectiveTokens(Brightness brightness) =>
      ThemeResolver.deriveTokens(
        seedColor: ThemeContrast.parseColor(seedColor),
        brightness: brightness,
        schemeVariant: ThemeResolver.parseSchemeVariant(schemeVariant),
        overrides: overrides,
      );

  Map<String, dynamic> toJson() => {
        'seedColor': seedColor,
        'schemeVariant': schemeVariant,
        'overrides': overrides,
        'coursePalette': coursePalette,
        'wallpapers': wallpapers,
        'componentOpacity': componentOpacity,
        'frostedEnabled': frostedEnabled,
        'frostedStrength': frostedStrength,
        'cardStyle': cardStyle,
        'decorations': decorations,
      };

  factory WorkshopVariantDraft.fromJson(Map<String, dynamic> json) {
    final rawWalls = (json['wallpapers'] as Map?) ?? const {};
    final rawDecos = (json['decorations'] as Map?) ?? const {};
    return WorkshopVariantDraft(
      seedColor: (json['seedColor'] as String? ?? '#147C72').toUpperCase(),
      schemeVariant: json['schemeVariant'] as String? ?? 'tonalSpot',
      overrides: {
        for (final entry in ((json['overrides'] as Map?) ?? const {}).entries)
          entry.key as String: (entry.value as String).toUpperCase(),
      },
      coursePalette: [
        for (final item in (json['coursePalette'] as List?) ?? const [])
          (item as String).toUpperCase(),
      ],
      wallpapers: {
        for (final entry in rawWalls.entries)
          entry.key as String: entry.value == null
              ? null
              : Map<String, dynamic>.from(entry.value as Map),
      },
      componentOpacity: ((json['componentOpacity'] as num?)?.toDouble() ?? 1.0)
          .clamp(0.75, 1.0),
      frostedEnabled: json['frostedEnabled'] == true,
      frostedStrength: ((json['frostedStrength'] as num?)?.toDouble() ?? 0.0)
          .clamp(0.0, 1.0),
      cardStyle: json['cardStyle'] == null
          ? null
          : Map<String, dynamic>.from(json['cardStyle'] as Map),
      decorations: {
        for (final entry in rawDecos.entries)
          entry.key as String: entry.value == null
              ? null
              : Map<String, dynamic>.from(entry.value as Map),
      },
    );
  }
}

/// 主题工坊完整可序列化编辑状态与打包器。
class ThemeWorkshopStateData {
  ThemeWorkshopStateData({
    required this.draftId,
    required this.themeId,
    this.version = 1,
    this.name = '我的主题',
    this.author = '创作者',
    this.description = '',
    this.license = 'CC-BY-4.0',
    List<String>? tags,
    this.shape = 'standard',
    required this.light,
    required this.dark,
    this.bottomNavStyle,
    this.iconTint = 'template',
    Map<String, Map<String, String>?>? navIcons,
    this.font,
    this.builtinLauncherIcon,
    this.customLauncherIconPath,
    Map<String, Map<String, dynamic>>? layout,
  })  : tags = List<String>.from(tags ?? const ['清新']),
        navIcons = Map<String, Map<String, String>?>.from(
          navIcons ?? const {},
        ),
        layout = Map<String, Map<String, dynamic>>.from(layout ?? const {});

  String draftId;
  String themeId;
  int version;
  String name;
  String author;
  String description;
  String license;
  List<String> tags;
  String shape;
  WorkshopVariantDraft light;
  WorkshopVariantDraft dark;
  String? bottomNavStyle;
  String iconTint;
  Map<String, Map<String, String>?> navIcons;
  Map<String, dynamic>? font;
  String? builtinLauncherIcon;
  String? customLauncherIconPath;
  Map<String, Map<String, dynamic>> layout;

  static String newUuid() {
    final rng = math.Random.secure();
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int s, int e) =>
        b.sublist(s, e).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h(0, 4)}-${h(4, 6)}-${h(6, 8)}-${h(8, 10)}-${h(10, 16)}';
  }

  factory ThemeWorkshopStateData.fromDefault({
    String seedHex = '#147C72',
    String? draftId,
  }) {
    WorkshopVariantDraft makeVariant(Brightness brightness) {
      final seed = ThemeContrast.parseColor(seedHex);
      final tokens = ThemeResolver.deriveTokens(
        seedColor: seed,
        brightness: brightness,
      );
      final courses = ThemeResolver.generateCoursePalette(
        seedColor: seed,
        brightness: brightness,
        background: ThemeContrast.parseColor(tokens['background']!),
        courseCardText: ThemeContrast.parseColor(tokens['courseCardText']!),
      );
      final fixed = ThemeResolver.autoFixVariant(
        brightness: brightness,
        tokens: tokens,
        coursePalette: courses,
      );
      return WorkshopVariantDraft(
        seedColor: seedHex.toUpperCase(),
        schemeVariant: 'tonalSpot',
        overrides: fixed.changedOverrides,
        coursePalette: fixed.coursePalette,
      );
    }

    return ThemeWorkshopStateData(
      draftId: draftId ?? newUuid(),
      themeId: newUuid(),
      light: makeVariant(Brightness.light),
      dark: makeVariant(Brightness.dark),
    );
  }

  factory ThemeWorkshopStateData.fromAppearance(
    ThemeAppearance appearance, {
    String? draftId,
  }) {
    final base = ThemeWorkshopStateData.fromDefault(draftId: draftId);
    final colorsGroup = appearance.group(ThemeGroup.colors);
    final wallsGroup = appearance.group(ThemeGroup.wallpapers);
    final matGroup = appearance.group(ThemeGroup.material);
    final decoGroup = appearance.group(ThemeGroup.decoration);

    WorkshopVariantDraft loadMode(Brightness brightness) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      final storedColor = colorsGroup?[mode] as Map?;
      final seed =
          (storedColor?['seedColor'] as String? ?? '#147C72').toUpperCase();
      final scheme = storedColor?['schemeVariant'] as String? ?? 'tonalSpot';
      final derived = ThemeResolver.deriveTokens(
        seedColor: ThemeContrast.parseColor(seed),
        brightness: brightness,
        schemeVariant: ThemeResolver.parseSchemeVariant(scheme),
      );
      final targetTokens = storedColor != null
          ? Map<String, String>.from(storedColor['tokens'] as Map)
          : AppPalette.defaults(brightness).toJson();
      final overrides = <String, String>{
        for (final entry in targetTokens.entries)
          if (derived[entry.key] != entry.value.toUpperCase())
            entry.key: entry.value.toUpperCase(),
      };
      final palette = storedColor != null
          ? [
              for (final c in storedColor['coursePalette'] as List)
                (c as String).toUpperCase(),
            ]
          : const ['#448AFF', '#00C853', '#9C27B0', '#FF5252', '#FF9800'];

      final walls = <String, Map<String, dynamic>?>{};
      if (wallsGroup != null && wallsGroup['legacy'] == null) {
        final modeWalls = wallsGroup[mode] as Map? ?? const {};
        for (final slot in const [
          'global',
          'home',
          'schedule',
          'me',
          'secondary'
        ]) {
          final item = modeWalls[slot] as Map?;
          if (item != null) walls[slot] = Map<String, dynamic>.from(item);
        }
      }

      var opacity = 1.0;
      var frostEnabled = false;
      var frostStrength = 0.0;
      Map<String, dynamic>? cardStyle;
      if (matGroup != null && matGroup['legacy'] != true) {
        final modeMat = matGroup[mode] as Map?;
        opacity = ((modeMat?['componentOpacity'] as num?)?.toDouble() ?? 1.0)
            .clamp(0.75, 1.0);
        final frost = modeMat?['frostedGlass'] as Map?;
        frostEnabled = frost?['enabled'] == true;
        frostStrength =
            ((frost?['strength'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0);
        if (modeMat?['cardStyle'] is Map) {
          cardStyle = Map<String, dynamic>.from(modeMat!['cardStyle'] as Map);
        }
      }

      final decos = <String, Map<String, dynamic>?>{};
      if (decoGroup != null) {
        final modeDeco = decoGroup[mode] as Map? ?? const {};
        for (final slot in const ['home', 'campus', 'me']) {
          final item = modeDeco[slot] as Map?;
          if (item != null) decos[slot] = Map<String, dynamic>.from(item);
        }
      }

      return WorkshopVariantDraft(
        seedColor: seed,
        schemeVariant: scheme,
        overrides: overrides,
        coursePalette: palette,
        wallpapers: walls,
        componentOpacity: opacity,
        frostedEnabled: frostEnabled,
        frostedStrength: frostStrength,
        cardStyle: cardStyle,
        decorations: decos,
      );
    }

    base.light = loadMode(Brightness.light);
    base.dark = loadMode(Brightness.dark);
    base.shape =
        appearance.group(ThemeGroup.shape)?['value'] as String? ?? 'standard';
    final nav = appearance.group(ThemeGroup.navigation);
    if (nav != null) {
      base.bottomNavStyle = nav['style'] as String?;
      base.iconTint = nav['iconTint'] as String? ?? 'template';
      final rawIcons = nav['icons'] as Map? ?? const {};
      for (final slot in const ['home', 'market', 'schedule', 'campus', 'me']) {
        final pair = rawIcons[slot] as Map?;
        if (pair != null &&
            pair['normal'] is String &&
            pair['selected'] is String) {
          base.navIcons[slot] = {
            'normal': pair['normal'] as String,
            'selected': pair['selected'] as String,
          };
        }
      }
    }
    final fontGroup = appearance.group(ThemeGroup.font);
    if (fontGroup != null && fontGroup['regular'] is String) {
      base.font = {
        'name': fontGroup['name'] as String? ?? '自定义字体',
        'regular': fontGroup['regular'] as String,
        if (fontGroup['bold'] is String) 'bold': fontGroup['bold'] as String,
        'license': fontGroup['license'] as String? ?? 'OFL-1.1',
      };
    }
    final launcherGroup = appearance.group(ThemeGroup.launcherIcon);
    if (launcherGroup != null) {
      base.builtinLauncherIcon = launcherGroup['builtin'] as String?;
      base.customLauncherIconPath = launcherGroup['custom'] as String?;
    }
    final layoutMap = appearance.group(ThemeGroup.layout)?['value'] as Map?;
    if (layoutMap != null) {
      for (final slot in const ['home', 'campus', 'me']) {
        if (layoutMap[slot] is Map) {
          base.layout[slot] = Map<String, dynamic>.from(layoutMap[slot] as Map);
        }
      }
    }
    return base;
  }

  factory ThemeWorkshopStateData.fromInstalled(
    InstalledTheme installed, {
    String? draftId,
  }) {
    final fullAppearance = const ThemeAppearance.empty().apply(
      installed.manifest,
      ThemeGroup.applicable,
      installed.directory,
    );
    final state = ThemeWorkshopStateData.fromAppearance(
      fullAppearance,
      draftId: draftId,
    );
    state.name = '${installed.manifest.name} 改版'.runes.length <= 20
        ? '${installed.manifest.name} 改版'
        : installed.manifest.name;
    state.author = installed.manifest.author;
    state.description = installed.manifest.description;
    state.license =
        installed.manifest.data['license'] as String? ?? 'CC-BY-4.0';
    final rawTags = installed.manifest.data['tags'] as List?;
    if (rawTags != null) {
      state.tags = [for (final t in rawTags) t as String];
    }
    return state;
  }

  WorkshopVariantDraft variant(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  ThemeAppearance buildAppearance() {
    Map<String, dynamic> colorEntry(Brightness b) {
      final v = variant(b);
      return {
        'seedColor': v.seedColor,
        'schemeVariant': v.schemeVariant,
        'tokens': v.effectiveTokens(b),
        'coursePalette': v.coursePalette,
      };
    }

    Map<String, dynamic> matEntry(Brightness b) {
      final v = variant(b);
      return {
        'componentOpacity': v.componentOpacity,
        'frostedGlass': {
          'enabled': v.frostedEnabled,
          'strength': v.frostedStrength,
        },
        if (v.cardStyle != null && v.cardStyle!.isNotEmpty)
          'cardStyle': v.cardStyle,
      };
    }

    return ThemeAppearance({
      'colors': {
        'source': null,
        'light': colorEntry(Brightness.light),
        'dark': colorEntry(Brightness.dark),
      },
      'shape': {'source': null, 'value': shape},
      'wallpapers': {
        'source': null,
        'light': light.wallpapers,
        'dark': dark.wallpapers,
      },
      'material': {
        'source': null,
        'light': matEntry(Brightness.light),
        'dark': matEntry(Brightness.dark),
      },
      'navigation': {
        'source': null,
        'style': bottomNavStyle ?? 'floating',
        'iconTint': iconTint,
        'icons': navIcons,
      },
      if (font != null) 'font': font!,
      if (builtinLauncherIcon != null || customLauncherIconPath != null)
        'launcherIcon': {
          'source': null,
          if (builtinLauncherIcon != null) 'builtin': builtinLauncherIcon,
          if (customLauncherIconPath != null) 'custom': customLauncherIconPath,
        },
      if (layout.isNotEmpty) 'layout': {'source': null, 'value': layout},
      'decoration': {
        'source': null,
        'light': light.decorations,
        'dark': dark.decorations,
      },
    });
  }

  List<ThemeContrastIssue> checkAllContrast() => [
        ...ThemeResolver.checkVariant(
          brightness: Brightness.light,
          tokens: light.effectiveTokens(Brightness.light),
          coursePalette: light.coursePalette,
        ),
        ...ThemeResolver.checkVariant(
          brightness: Brightness.dark,
          tokens: dark.effectiveTokens(Brightness.dark),
          coursePalette: dark.coursePalette,
        ),
      ];

  Map<String, dynamic> toDraftJson() => {
        'draftId': draftId,
        'themeId': themeId,
        'version': version,
        'name': name,
        'author': author,
        'description': description,
        'license': license,
        'tags': tags,
        'shape': shape,
        'light': light.toJson(),
        'dark': dark.toJson(),
        'bottomNavStyle': bottomNavStyle,
        'iconTint': iconTint,
        'navIcons': navIcons,
        'font': font,
        'builtinLauncherIcon': builtinLauncherIcon,
        'customLauncherIconPath': customLauncherIconPath,
        'layout': layout,
      };

  factory ThemeWorkshopStateData.fromDraftJson(Map<String, dynamic> json) {
    final rawNavIcons = (json['navIcons'] as Map?) ?? const {};
    final rawLayout = (json['layout'] as Map?) ?? const {};
    return ThemeWorkshopStateData(
      draftId: json['draftId'] as String? ?? newUuid(),
      themeId: json['themeId'] as String? ?? newUuid(),
      version: json['version'] as int? ?? 1,
      name: json['name'] as String? ?? '我的主题',
      author: json['author'] as String? ?? '创作者',
      description: json['description'] as String? ?? '',
      license: json['license'] as String? ?? 'CC-BY-4.0',
      tags: [
        for (final t in (json['tags'] as List?) ?? const ['清新']) t as String,
      ],
      shape: json['shape'] as String? ?? 'standard',
      light: WorkshopVariantDraft.fromJson(
        Map<String, dynamic>.from(json['light'] as Map),
      ),
      dark: WorkshopVariantDraft.fromJson(
        Map<String, dynamic>.from(json['dark'] as Map),
      ),
      bottomNavStyle: json['bottomNavStyle'] as String?,
      iconTint: json['iconTint'] as String? ?? 'template',
      navIcons: {
        for (final entry in rawNavIcons.entries)
          entry.key as String: entry.value == null
              ? null
              : {
                  'normal': (entry.value as Map)['normal'] as String,
                  'selected': (entry.value as Map)['selected'] as String,
                },
      },
      font: json['font'] == null
          ? null
          : Map<String, dynamic>.from(json['font'] as Map),
      builtinLauncherIcon: json['builtinLauncherIcon'] as String?,
      customLauncherIconPath: json['customLauncherIconPath'] as String?,
      layout: {
        for (final entry in rawLayout.entries)
          if (entry.value is Map)
            entry.key as String: Map<String, dynamic>.from(entry.value as Map),
      },
    );
  }

  /// 导出规范 `.sltheme` 字节（长边 >2560 的壁纸缩小为 JPEG q88，原图不烘焙 adjustments，最后经 codec 复核）。
  Future<Uint8List> exportPack({
    required String appVersion,
    Uint8List? renderedLightPng,
    Uint8List? renderedDarkPng,
    bool requireContrastPass = true,
  }) async =>
      (await _exportPack(
        appVersion: appVersion,
        renderedLightPng: renderedLightPng,
        renderedDarkPng: renderedDarkPng,
        requireContrastPass: requireContrastPass,
      ))
          .$1;

  Future<(Uint8List, PreparedThemePack)> _exportPack({
    required String appVersion,
    Uint8List? renderedLightPng,
    Uint8List? renderedDarkPng,
    required bool requireContrastPass,
    Set<ThemeGroup> applying = const {},
  }) async {
    final issues = checkAllContrast();
    if (requireContrastPass && issues.isNotEmpty) {
      throw ThemeWorkshopContrastException(issues);
    }

    final rawFiles = <String, Uint8List>{};
    final localToArchive = <String, String>{};
    var seq = 0;
    bool includes(ThemeGroup group) =>
        applying.isEmpty || applying.contains(group);

    Future<String> registerAsset(
      String localPath,
      String folder, {
      bool isWallpaper = false,
    }) async {
      final key = '$folder::$localPath';
      if (localToArchive.containsKey(key)) return localToArchive[key]!;
      var bytes =
          isWallpaper && ThemeProvider.isBundledAssetBackground(localPath)
              ? Uint8List.sublistView(await rootBundle
                  .load(ThemeProvider.resolveBundledAssetPath(localPath)))
              : await File(localPath).readAsBytes();
      var ext = path.extension(localPath).toLowerCase().replaceFirst('.', '');
      if (ext == 'jpeg') ext = 'jpg';
      if (ext.isEmpty) ext = folder == 'fonts' ? 'ttf' : 'png';

      if (isWallpaper) {
        final resized = await _resizeWallpaper(bytes);
        if (resized != null) {
          bytes = resized;
          ext = 'jpg';
        }
      }

      final archivePath = '$folder/item_${++seq}.$ext';
      localToArchive[key] = archivePath;
      rawFiles[archivePath] = bytes;
      return archivePath;
    }

    Future<Map<String, dynamic>> buildManifestVariant(Brightness b) async {
      final v = variant(b);
      Map<String, dynamic>? wallsOut;
      if (includes(ThemeGroup.wallpapers) &&
          (applying.contains(ThemeGroup.wallpapers) ||
              v.wallpapers.values.any((w) => w != null))) {
        wallsOut = {};
        for (final slot in const [
          'global',
          'home',
          'schedule',
          'me',
          'secondary'
        ]) {
          final item = v.wallpapers[slot];
          if (item == null || item['portrait'] == null) {
            wallsOut[slot] = null;
            continue;
          }
          wallsOut[slot] = {
            'portrait': await registerAsset(
              item['portrait'] as String,
              'wallpaper',
              isWallpaper: true,
            ),
            if (item['landscape'] != null)
              'landscape': await registerAsset(
                item['landscape'] as String,
                'wallpaper',
                isWallpaper: true,
              ),
            'fit': item['fit'] ?? 'cover',
            'focalX': (item['focalX'] as num? ?? 0.5).toDouble(),
            'focalY': (item['focalY'] as num? ?? 0.5).toDouble(),
            'blur': (item['blur'] as num? ?? 0.0).toDouble().clamp(0.0, 20.0),
            'scrim': (item['scrim'] as num? ?? 0.0).toDouble().clamp(0.0, 0.6),
            if (item['adjustments'] != null)
              'adjustments':
                  Map<String, dynamic>.from(item['adjustments'] as Map),
          };
        }
      }

      Map<String, dynamic>? decosOut;
      if (includes(ThemeGroup.decoration) &&
          v.decorations.values.any((d) => d != null)) {
        decosOut = {};
        for (final slot in const ['home', 'campus', 'me']) {
          final item = v.decorations[slot];
          if (item == null) {
            decosOut[slot] = null;
            continue;
          }
          final bg = item['background'] as Map?;
          final stickers = (item['stickers'] as List?) ?? const [];
          decosOut[slot] = {
            if (bg != null && bg['image'] != null)
              'background': {
                ...Map<String, dynamic>.from(bg),
                'image':
                    await registerAsset(bg['image'] as String, 'decorations'),
              },
            'stickers': [
              for (final s in stickers)
                if (s is Map && s['image'] != null)
                  {
                    ...Map<String, dynamic>.from(s),
                    'image': await registerAsset(
                      s['image'] as String,
                      'decorations',
                    ),
                  },
            ],
          };
        }
      }

      return {
        'seedColor': v.seedColor,
        'schemeVariant': v.schemeVariant,
        'tokens': v.effectiveTokens(b),
        'coursePalette': v.coursePalette,
        if (wallsOut != null) 'wallpapers': wallsOut,
        if (includes(ThemeGroup.material) &&
            (applying.contains(ThemeGroup.material) ||
                v.componentOpacity < 1.0 ||
                v.frostedEnabled)) ...{
          'componentOpacity': v.componentOpacity,
          'frostedGlass': {
            'enabled': v.frostedEnabled,
            'strength': v.frostedEnabled ? v.frostedStrength : 0.0,
          },
        },
        if (includes(ThemeGroup.material) &&
            v.cardStyle != null &&
            v.cardStyle!.isNotEmpty)
          'cardStyle': v.cardStyle,
        if (decosOut != null) 'decorations': decosOut,
      };
    }

    final lightMap = await buildManifestVariant(Brightness.light);
    final darkMap = await buildManifestVariant(Brightness.dark);

    Map<String, dynamic>? bottomNavOut;
    final hasAnyNavIcon = navIcons.values.any((pair) => pair != null);
    if (includes(ThemeGroup.navigation) &&
        (bottomNavStyle != null || hasAnyNavIcon)) {
      final iconsOut = <String, dynamic>{};
      for (final slot in const ['home', 'market', 'schedule', 'campus', 'me']) {
        final pair = navIcons[slot];
        if (pair == null) {
          iconsOut[slot] = null;
        } else {
          iconsOut[slot] = {
            'normal': await registerAsset(pair['normal']!, 'icons'),
            'selected': await registerAsset(pair['selected']!, 'icons'),
          };
        }
      }
      bottomNavOut = {
        if (bottomNavStyle != null) 'style': bottomNavStyle,
        'iconTint': iconTint,
        'icons': iconsOut,
      };
    }

    Map<String, dynamic>? fontOut;
    if (includes(ThemeGroup.font) && font != null && font!['regular'] != null) {
      fontOut = {
        'name': font!['name'] as String? ?? '自定义字体',
        'regular': await registerAsset(font!['regular'] as String, 'fonts'),
        if (font!['bold'] != null)
          'bold': await registerAsset(font!['bold'] as String, 'fonts'),
        'license': font!['license'] as String? ?? 'OFL-1.1',
      };
    }

    Map<String, dynamic>? launcherOut;
    if (includes(ThemeGroup.launcherIcon) &&
        (builtinLauncherIcon != null || customLauncherIconPath != null)) {
      launcherOut = {
        if (builtinLauncherIcon != null) 'builtin': builtinLauncherIcon,
        if (customLauncherIconPath != null)
          'custom': await registerAsset(customLauncherIconPath!, 'icons'),
      };
    }

    rawFiles['preview/light.png'] =
        renderedLightPng ?? await _fallbackPreviewPng(lightMap);
    rawFiles['preview/dark.png'] =
        renderedDarkPng ?? await _fallbackPreviewPng(darkMap);

    final safeVersion =
        RegExp(r'^\d+\.\d+\.\d+$').hasMatch(appVersion) ? appVersion : '1.0.0';
    final safeName = name.trim().isEmpty
        ? '未命名主题'
        : String.fromCharCodes(name.trim().runes.take(20));
    final safeAuthor = author.trim().isEmpty
        ? '创作者'
        : String.fromCharCodes(author.trim().runes.take(20));
    final safeDesc = String.fromCharCodes(description.trim().runes.take(200));

    final manifestJson = <String, dynamic>{
      'formatVersion': 1,
      'minAppVersion': safeVersion,
      'id': themeId,
      'version': version,
      'name': safeName,
      'author': safeAuthor,
      'description': safeDesc,
      'license': license,
      if (tags.isNotEmpty) 'tags': tags.take(5).toList(),
      'preview': {
        'light': 'preview/light.png',
        'dark': 'preview/dark.png',
      },
      'shape': shape,
      'light': lightMap,
      'dark': darkMap,
      if (bottomNavOut != null) 'bottomNav': bottomNavOut,
      if (fontOut != null) 'font': fontOut,
      if (launcherOut != null) 'launcherIcon': launcherOut,
      if (includes(ThemeGroup.layout) && layout.isNotEmpty) 'layout': layout,
    };

    final manifest = ThemeManifest.parse(manifestJson, appVersion: safeVersion);
    final encoded = await ThemePackCodec.encode(manifest, rawFiles);
    final prepared =
        await ThemePackCodec.decode(encoded, appVersion: safeVersion);
    return (encoded, prepared);
  }

  static Future<Uint8List?> _resizeWallpaper(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final longest = math.max(descriptor.width, descriptor.height);
      if (longest <= 2560) return null;
      final scale = 2560 / longest;
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      image = (await codec.getNextFrame()).image;
      final pixels =
          (await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
      final width = image.width;
      final height = image.height;
      return Isolate.run(() => Uint8List.fromList(img.encodeJpg(
            img.Image.fromBytes(
                width: width,
                height: height,
                bytes: pixels.buffer,
                bytesOffset: pixels.offsetInBytes,
                numChannels: 4),
            quality: 88,
          )));
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  static Future<Uint8List> _fallbackPreviewPng(Map<String, dynamic> variant) =>
      Isolate.run(() {
        final tokens = variant['tokens'] as Map<String, dynamic>;
        img.ColorRgba8 c(String k) {
          final parsed = ThemeContrast.parseColor(tokens[k] as String);
          return img.ColorRgba8(
            (parsed.r * 255).round() & 0xff,
            (parsed.g * 255).round() & 0xff,
            (parsed.b * 255).round() & 0xff,
            (parsed.a * 255).round() & 0xff,
          );
        }

        final canvas = img.Image(width: 1080, height: 2340);
        img.fill(canvas, color: c('background'));
        img.fillRect(
          canvas,
          x1: 0,
          y1: 0,
          x2: 1080,
          y2: 168,
          color: c('appBarBackground'),
        );
        img.fillRect(
          canvas,
          x1: 64,
          y1: 236,
          x2: 1016,
          y2: 880,
          color: c('card'),
          radius: 36,
        );
        img.fillRect(
          canvas,
          x1: 118,
          y1: 300,
          x2: 560,
          y2: 350,
          color: c('textPrimary'),
          radius: 12,
        );
        img.fillRect(
          canvas,
          x1: 118,
          y1: 386,
          x2: 840,
          y2: 422,
          color: c('textSecondary'),
          radius: 10,
        );
        img.fillRect(
          canvas,
          x1: 118,
          y1: 500,
          x2: 420,
          y2: 596,
          color: c('primary'),
          radius: 24,
        );
        img.fillRect(
          canvas,
          x1: 64,
          y1: 2120,
          x2: 1016,
          y2: 2268,
          color: c('navBackground'),
          radius: 48,
        );
        return Uint8List.fromList(img.encodePng(canvas, level: 1));
      });
}

/// 主题工坊主页面（P2）：实时共享组件预览、十项能力编辑、对比度修正、草稿自动保存与规范包导出。
class ThemeWorkshopScreen extends StatefulWidget {
  const ThemeWorkshopScreen({
    super.key,
    this.initialState,
    this.draftStore,
    this.pickFilePath,
    this.saveExportFile,
    this.shareExportFile,
    this.appVersion,
    this.deviceSettingsBuilder,
  });

  final ThemeWorkshopStateData? initialState;
  final ThemeWorkshopDraftStore? draftStore;
  final Future<String?> Function(String purpose)? pickFilePath;
  final Future<String?> Function(String fileName, Uint8List bytes)?
      saveExportFile;
  final Future<void> Function(String fileName, Uint8List bytes, Rect? origin)?
      shareExportFile;
  final String? appVersion;
  final WidgetBuilder? deviceSettingsBuilder;

  @override
  State<ThemeWorkshopScreen> createState() => _ThemeWorkshopScreenState();
}

class _ThemeWorkshopScreenState extends State<ThemeWorkshopScreen> {
  static const _allowedTags = [
    '浅色',
    '深色',
    '明暗自适应',
    '简约',
    '清新',
    '可爱',
    '动漫',
    '风景',
    '校园',
    '节日',
    '纯色',
    '高对比',
    '复古',
    '科技',
  ];

  static const _seedPresets = [
    ('#147C72', '沈理青'),
    ('#2F7FD8', '海盐蓝'),
    ('#C9617E', '樱粉'),
    ('#3E6B4F', '松叶绿'),
    ('#5B7C8A', '墨夜蓝灰'),
    ('#7C5295', '暮紫'),
    ('#B86B28', '暖琥珀'),
  ];

  late ThemeWorkshopDraftStore _draftStore;
  late ThemeWorkshopStateData _state;
  late Map<ThemeGroup, String> _appliedGroups;
  Brightness _brightness = Brightness.light;
  WorkshopSamplePage _samplePage = WorkshopSamplePage.home;
  WorkshopSampleState _sampleState = WorkshopSampleState.normal;
  WorkshopTab _activeTab = WorkshopTab.colors;
  bool _showDialogOverlay = false;
  bool _advancedTokensExpanded = false;
  String? _highlightedToken;
  String _wallpaperSlot = 'global';
  String _headerSlot = 'home';
  final _editorAnchor = GlobalKey();

  Timer? _autosaveTimer;
  bool _savingDraft = false;
  bool _draftSaveFailed = false;
  bool _loadingStartPoints = false;
  bool _exporting = false;
  String? _bannerMessage;
  bool _forceAllowPop = false;

  late TextEditingController _seedHexController;

  @override
  void initState() {
    super.initState();
    final provider = context.read<ThemeProvider?>();
    _draftStore = widget.draftStore ??
        ThemeWorkshopDraftStore(
          themesDirectory: null,
        );
    _state = widget.initialState ?? _currentDraft(provider);
    _appliedGroups = _groupValues(_state.buildAppearance());
    _brightness = provider?.effectiveBrightness ?? Brightness.light;
    _seedHexController = TextEditingController(
      text: _state.variant(_brightness).seedColor,
    );
    _ensureFontLoadedIfAny();
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _seedHexController.dispose();
    super.dispose();
  }

  WorkshopVariantDraft get _currentVariant => _state.variant(_brightness);

  static Map<ThemeGroup, String> _groupValues(ThemeAppearance appearance) => {
        for (final group in ThemeGroup.applicable)
          if (group != ThemeGroup.launcherIcon && group != ThemeGroup.widgets)
            group: jsonEncode({...?appearance.group(group)}..remove('source')),
      };

  ThemeWorkshopStateData _currentDraft(ThemeProvider? provider,
      {String? draftId}) {
    if (provider == null) {
      return ThemeWorkshopStateData.fromDefault(draftId: draftId);
    }
    final appearance = provider.persistedAppearance;
    final draft =
        ThemeWorkshopStateData.fromAppearance(appearance, draftId: draftId);
    draft.bottomNavStyle ??= provider.bottomNavStyle.storageValue;
    String? usablePath(String? raw) {
      if (raw == null) return null;
      if (ThemeProvider.isBundledAssetBackground(raw)) return raw;
      if (!ThemeProvider.isLocalFileBackground(raw)) return null;
      return raw.startsWith('file://')
          ? File.fromUri(Uri.parse(raw)).path
          : raw;
    }

    if (!provider.usesThemeWallpapers && provider.shouldShowCustomBackground) {
      final portrait = usablePath(provider.backgroundImage);
      final landscape = usablePath(provider.landscapeBackgroundImage);
      if (portrait != null || landscape != null) {
        for (final variant in [draft.light, draft.dark]) {
          variant.wallpapers['global'] = {
            'portrait': portrait ?? landscape,
            if (landscape != null && portrait != null) 'landscape': landscape,
            'fit': 'cover',
            'blur': provider.backgroundBlur.clamp(0.0, 20.0),
            'scrim': variant == draft.dark ? 0.35 : 0.25,
          };
        }
      }
    }
    final material = appearance.group(ThemeGroup.material);
    if (material == null || material['legacy'] == true) {
      for (final variant in [draft.light, draft.dark]) {
        variant.componentOpacity = provider.effectiveComponentOpacity;
        variant.frostedEnabled = provider.frostedGlass;
        variant.frostedStrength = provider.frostedGlassStrength;
      }
    }
    return draft;
  }

  void _mutate(VoidCallback fn) {
    setState(() {
      fn();
      _bannerMessage = null;
    });
    _scheduleAutosave();
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(const Duration(milliseconds: 800), _saveDraftNow);
  }

  Future<void> _saveDraftNow() async {
    _autosaveTimer?.cancel();
    if (!mounted) return;
    setState(() => _savingDraft = true);
    try {
      await _draftStore.save(_state.draftId, _state.toDraftJson());
      if (mounted) {
        setState(() {
          _savingDraft = false;
          _draftSaveFailed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _savingDraft = false;
          _draftSaveFailed = true;
        });
      }
    }
  }

  void _ensureFontLoadedIfAny() {
    final appearance = _state.buildAppearance();
    final fg = appearance.group(ThemeGroup.font);
    if (fg == null) return;
    unawaited(
      ThemeFontRegistry.ensureLoaded(fg).then((loaded) {
        if (loaded != null && mounted) setState(() {});
      }),
    );
  }

  ImageProvider? _resolveLocalImage(String rawPath) {
    if (rawPath.isEmpty) return null;
    if (ThemeProvider.isBundledAssetBackground(rawPath)) {
      return AssetImage(ThemeProvider.resolveBundledAssetPath(rawPath));
    }
    return FileImage(File(rawPath));
  }

  Future<String?> _pickRawFile(
    String purpose, {
    List<String>? allowedExtensions,
  }) async {
    try {
      if (widget.pickFilePath != null) {
        return await widget.pickFilePath!(purpose);
      }
      final picked = await FilePicker.platform.pickFiles(
        type: allowedExtensions == null ? FileType.any : FileType.custom,
        allowedExtensions: allowedExtensions,
        withData: false,
      );
      return picked?.files.single.path;
    } on PlatformException {
      throw ThemePackError(
          'theme_field_invalid', purpose, '无法选取文件，请检查文件权限后重试。');
    }
  }

  void _handlePreviewFocus(WorkshopFocusTarget target) {
    setState(() {
      switch (target) {
        case WorkshopFocusTarget.colors:
          _activeTab = WorkshopTab.colors;
        case WorkshopFocusTarget.courses:
          _activeTab = WorkshopTab.courses;
        case WorkshopFocusTarget.wallpaper:
          _activeTab = WorkshopTab.wallpapers;
        case WorkshopFocusTarget.material:
          _activeTab = WorkshopTab.material;
        case WorkshopFocusTarget.layoutHome:
          _headerSlot = 'home';
          _activeTab = WorkshopTab.layout;
        case WorkshopFocusTarget.layoutCampus:
          _headerSlot = 'campus';
          _activeTab = WorkshopTab.layout;
        case WorkshopFocusTarget.layoutMe:
          _headerSlot = 'me';
          _activeTab = WorkshopTab.layout;
        case WorkshopFocusTarget.decoHome:
          _headerSlot = 'home';
          _activeTab = WorkshopTab.decoration;
        case WorkshopFocusTarget.decoCampus:
          _headerSlot = 'campus';
          _activeTab = WorkshopTab.decoration;
        case WorkshopFocusTarget.decoMe:
          _headerSlot = 'me';
          _activeTab = WorkshopTab.decoration;
        case WorkshopFocusTarget.icons:
          _activeTab = WorkshopTab.icons;
        case WorkshopFocusTarget.widgets:
          _activeTab = WorkshopTab.widgets;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _editorAnchor.currentContext;
      if (anchor != null) Scrollable.ensureVisible(anchor);
    });
  }

  Future<void> _showStartPointMenu() async {
    if (_loadingStartPoints) return;
    setState(() => _loadingStartPoints = true);
    final provider = context.read<ThemeProvider?>();
    late final List<InstalledTheme> installed;
    late final List<Map<String, dynamic>> drafts;
    try {
      installed =
          provider == null ? const [] : await provider.installedThemes();
      drafts = await _draftStore.list();
    } catch (_) {
      if (mounted) {
        setState(() => _bannerMessage = '无法读取本机主题和草稿，请重试。');
      }
      return;
    } finally {
      if (mounted) setState(() => _loadingStartPoints = false);
    }
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;

    final chosen = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return AppCardSurface(
          decoration: BoxDecoration(
            color: Theme.of(sheetCtx).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          ),
          child: SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(
                  title: Text(
                    '选择编辑起点',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.auto_fix_high_outlined),
                  title: const Text('默认配色起点'),
                  subtitle: const Text('从干净的种子色与满足对比度的全套默认值开始'),
                  onTap: () => Navigator.of(sheetCtx).pop('default'),
                ),
                if (provider != null)
                  ListTile(
                    leading: const Icon(Icons.palette_outlined),
                    title: const Text('当前生效外观'),
                    subtitle: Text(provider.currentAppearanceSummary),
                    onTap: () => Navigator.of(sheetCtx).pop('current'),
                  ),
                for (final item in installed)
                  ListTile(
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: Text('已安装：${item.manifest.name}'),
                    subtitle: Text(
                        '${item.manifest.author} · v${item.manifest.version}'),
                    onTap: () => Navigator.of(sheetCtx).pop(item),
                  ),
                for (final draft in drafts)
                  ListTile(
                    leading: const Icon(Icons.drafts_outlined),
                    title: Text('草稿：${draft['name'] ?? '未命名'}'),
                    subtitle: Text('${draft['updatedAt'] ?? ''}'),
                    onTap: () => Navigator.of(sheetCtx).pop(draft),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || chosen == null) return;
    setState(() {
      if (chosen == 'default') {
        _state = ThemeWorkshopStateData.fromDefault(draftId: _state.draftId);
      } else if (chosen == 'current' && provider != null) {
        _state = _currentDraft(provider, draftId: _state.draftId);
        _appliedGroups = _groupValues(_state.buildAppearance());
      } else if (chosen is InstalledTheme) {
        _state = ThemeWorkshopStateData.fromInstalled(
          chosen,
          draftId: _state.draftId,
        );
      } else if (chosen is Map<String, dynamic>) {
        _state = ThemeWorkshopStateData.fromDraftJson(chosen);
      }
      _seedHexController.text = _currentVariant.seedColor;
      _highlightedToken = null;
      _bannerMessage = null;
    });
    _ensureFontLoadedIfAny();
    _scheduleAutosave();
  }

  Future<(Uint8List, Uint8List)> _captureOffscreenPreviews(
    ThemeAppearance appearance,
  ) async {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      final l = await _state.exportPack(appVersion: '1.0.0');
      return (l, l);
    }
    final lightKey = GlobalKey();
    final darkKey = GlobalKey();
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: -4000,
        top: -4000,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              key: lightKey,
              child: ThemeWorkshopExportStage(
                appearance: appearance,
                brightness: Brightness.light,
                assetResolver: _resolveLocalImage,
              ),
            ),
            RepaintBoundary(
              key: darkKey,
              child: ThemeWorkshopExportStage(
                appearance: appearance,
                brightness: Brightness.dark,
                assetResolver: _resolveLocalImage,
              ),
            ),
          ],
        ),
      ),
    );
    overlay.insert(entry);
    try {
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      Future<Uint8List> grab(GlobalKey key) async {
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 3.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return byteData!.buffer.asUint8List();
      }

      return (await grab(lightKey), await grab(darkKey));
    } finally {
      entry.remove();
    }
  }

  Future<void> _openExportSheet() async {
    if (_exporting) return;
    final issues = _state.checkAllContrast();
    if (issues.isNotEmpty) {
      final first = issues.first;
      setState(() {
        _brightness = first.brightness;
        _seedHexController.text = _currentVariant.seedColor;
        _activeTab = first.background.startsWith('coursePalette')
            ? WorkshopTab.courses
            : WorkshopTab.colors;
        _advancedTokensExpanded = true;
        _highlightedToken = first.foreground;
        _bannerMessage =
            '存在 ${issues.length} 项对比度未达标（已定位到 ${first.foreground} / ${first.background}），请点击“自动修正”或微调后再导出。';
      });
      return;
    }

    final nameCtrl = TextEditingController(text: _state.name);
    final authorCtrl = TextEditingController(text: _state.author);
    final descCtrl = TextEditingController(text: _state.description);
    var selectedLicense = _state.license;
    final selectedTags = Set<String>.of(_state.tags);

    final action = await showAppDialog<String>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AppAlertDialog(
          title: const Text('导出规范主题包'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameCtrl,
                  maxLength: 20,
                  decoration: const InputDecoration(labelText: '主题名称'),
                ),
                TextField(
                  controller: authorCtrl,
                  maxLength: 20,
                  decoration: const InputDecoration(labelText: '作者署名'),
                ),
                TextField(
                  controller: descCtrl,
                  maxLength: 200,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: '主题简介（可选）'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: selectedLicense,
                  decoration: const InputDecoration(labelText: '授权协议'),
                  items: const [
                    DropdownMenuItem(value: 'CC0-1.0', child: Text('CC0-1.0')),
                    DropdownMenuItem(
                      value: 'CC-BY-4.0',
                      child: Text('CC-BY-4.0'),
                    ),
                    DropdownMenuItem(
                      value: 'CC-BY-NC-4.0',
                      child: Text('CC-BY-NC-4.0'),
                    ),
                    DropdownMenuItem(
                      value: 'personal-use',
                      child: Text('仅个人使用 (personal-use)'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setDialogState(() => selectedLicense = v);
                  },
                ),
                const SizedBox(height: 10),
                const Text('标签（最多 5 个）', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in _allowedTags)
                      FilterChip(
                        label: Text(tag),
                        selected: selectedTags.contains(tag),
                        onSelected: (on) {
                          setDialogState(() {
                            if (on && selectedTags.length < 5) {
                              selectedTags.add(tag);
                            } else {
                              selectedTags.remove(tag);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('取消'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(dialogCtx).pop('share'),
              child: const Text('系统分享'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(dialogCtx).pop('save'),
              child: const Text('保存文件'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(dialogCtx).pop('submit'),
              child: const Text('投稿到商城'),
            ),
          ],
        ),
      ),
    );

    final nextName = nameCtrl.text.trim();
    final nextAuthor = authorCtrl.text.trim();
    final nextDesc = descCtrl.text.trim();
    nameCtrl.dispose();
    authorCtrl.dispose();
    descCtrl.dispose();
    if (action == null || !mounted) return;

    _mutate(() {
      if (nextName.isNotEmpty) _state.name = nextName;
      if (nextAuthor.isNotEmpty) _state.author = nextAuthor;
      _state.description = nextDesc;
      _state.license = selectedLicense;
      _state.tags = selectedTags.toList();
    });

    await _runPackAction(action);
  }

  Set<ThemeGroup> _editedGroups(ThemeAppearance appearance) => {
        for (final entry in _groupValues(appearance).entries)
          if (_appliedGroups[entry.key] != entry.value) entry.key,
      };

  Future<void> _runPackAction(String action) async {
    if (_exporting) return;
    final applying = action == 'apply';
    final draft = ThemeWorkshopStateData.fromDraftJson(
      jsonDecode(jsonEncode(_state.toDraftJson())) as Map<String, dynamic>,
    );
    final appearance = draft.buildAppearance();
    final groups = applying ? _editedGroups(appearance) : <ThemeGroup>{};
    if (applying && groups.isEmpty) return;

    _autosaveTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _exporting = true;
      _bannerMessage = null;
    });

    try {
      final provider = context.read<ThemeProvider>();
      if (applying) {
        final previous = (await provider.installedThemes())
            .where((theme) => theme.manifest.id == draft.themeId)
            .firstOrNull;
        if (previous != null && previous.manifest.version >= draft.version) {
          draft.version = previous.manifest.version + 1;
          _state.version = draft.version;
        }
      }
      await _saveDraftNow();
      final appVer = widget.appVersion ?? await _resolveAppVersion();
      if (!mounted) return;
      final (lightPng, darkPng) = await _captureOffscreenPreviews(appearance);
      final (bytes, prepared) = await draft._exportPack(
        appVersion: appVer,
        renderedLightPng: lightPng,
        renderedDarkPng: darkPng,
        requireContrastPass: !applying,
        applying: groups,
      );
      if (!mounted) return;

      final fileName =
          '${ThemeAppearanceExporter.sanitizeFileName(draft.name)}.sltheme';
      if (action == 'submit') {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ThemeSubmissionScreen(
              initialPackageBytes: bytes,
              initialManifest: prepared.manifest,
            ),
          ),
        );
      } else if (applying) {
        final installed = await provider.installTheme(prepared);
        await provider.applyInstalledTheme(
          installed,
          groups,
          resetMissingGroups: true,
        );
        if (mounted) {
          _appliedGroups = _groupValues(appearance);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('主题已应用')),
          );
        }
      } else if (action == 'share') {
        final box = context.findRenderObject() as RenderBox?;
        final origin =
            box == null ? null : box.localToGlobal(Offset.zero) & box.size;
        if (widget.shareExportFile != null) {
          await widget.shareExportFile!(fileName, bytes, origin);
        } else {
          await Share.shareXFiles(
            [
              XFile.fromData(
                bytes,
                name: fileName,
                mimeType: 'application/vnd.sylulive.theme+zip',
              ),
            ],
            fileNameOverrides: [fileName],
            sharePositionOrigin: origin,
          );
        }
      } else if (action == 'save') {
        final savedPath = widget.saveExportFile != null
            ? await widget.saveExportFile!(fileName, bytes)
            : await FilePicker.platform.saveFile(
                dialogTitle: '保存主题包',
                fileName: fileName,
                bytes: bytes,
              );
        if (savedPath != null && savedPath.isNotEmpty) {
          final file = File(savedPath);
          if (!await file.exists() || await file.length() == 0) {
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes, flush: true);
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已保存 $fileName')),
            );
          }
        }
      }
    } on ThemePackError catch (e) {
      if (mounted) setState(() => _bannerMessage = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _bannerMessage =
            applying ? '主题应用失败，编辑内容已保留，请重试。' : '导出主题包失败，请检查素材后重试。');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<String> _resolveAppVersion() async {
    try {
      return (await PackageInfo.fromPlatform())
          .version
          .split('+')
          .first
          .split('-')
          .first;
    } catch (_) {
      return '1.0.0';
    }
  }

  Future<void> _confirmDiscardOnSaveFailure() async {
    final choice = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: const Text('草稿尚未保存'),
        content: const Text('自动保存草稿失败，现在离开会丢失未保存的修改。是否重试保存？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: const Text('留在工坊'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: const Text('放弃未保存修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('retry'),
            child: const Text('重试保存'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'retry') {
      await _saveDraftNow();
      if (!_draftSaveFailed && mounted) {
        Navigator.of(context).pop();
      }
    } else if (choice == 'discard') {
      setState(() => _forceAllowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  void _selectBrightness(Brightness brightness) {
    setState(() {
      _brightness = brightness;
      _seedHexController.text = _currentVariant.seedColor;
    });
  }

  Widget _sample(
    ThemeAppearance appearance, {
    ValueChanged<WorkshopFocusTarget>? onFocusTarget,
  }) =>
      ThemeWorkshopSampleStage(
        appearance: appearance,
        brightness: _brightness,
        assetResolver: _resolveLocalImage,
        page: _samplePage,
        sampleState: _sampleState,
        showDialogOverlay: _showDialogOverlay,
        onFocusTarget: onFocusTarget,
      );

  Widget _scaledSample(ThemeAppearance appearance) => FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 360,
          height: 570,
          child: _sample(appearance),
        ),
      );

  Future<void> _showFullscreenPreview(ThemeAppearance appearance) =>
      Navigator.of(context)
          .push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => StatefulBuilder(
            builder: (routeContext, updatePreview) => Scaffold(
              appBar: AppBar(title: const Text('全屏预览')),
              body: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final page in WorkshopSamplePage.values)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text(page.label),
                                  selected: _samplePage == page,
                                  onSelected: (_) =>
                                      updatePreview(() => _samplePage = page),
                                ),
                              ),
                          ],
                        ),
                      ),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final state in WorkshopSampleState.values)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text(state.label),
                                  selected: _sampleState == state,
                                  onSelected: (_) =>
                                      updatePreview(() => _sampleState = state),
                                ),
                              ),
                            FilterChip(
                              label: const Text('弹窗层'),
                              selected: _showDialogOverlay,
                              onSelected: (selected) => updatePreview(
                                  () => _showDialogOverlay = selected),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (_, constraints) =>
                              constraints.maxHeight < 230
                                  ? _scaledSample(appearance)
                                  : _sample(
                                      appearance,
                                      onFocusTarget: (target) {
                                        Navigator.of(routeContext).pop();
                                        _handlePreviewFocus(target);
                                      },
                                    ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      )
          .then((_) {
        if (mounted) setState(() {});
      });

  Widget _buildPreviewCard(ThemeAppearance appearance) {
    final tokens = AppThemeTokens.of(context);
    final preview = appearance.buildTheme(_brightness).colorScheme;
    final provider = context.watch<ThemeProvider?>();
    final typography = Theme.of(context).textTheme;
    final accentWash =
        Color.alphaBlend(preview.primary.withValues(alpha: .13), tokens.card);
    return AppCardSurface(
      decoration: BoxDecoration(
        border: Border.all(color: tokens.cardBorder),
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [accentWash, tokens.card],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: preview.onSurface,
                borderRadius: BorderRadius.circular(19),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .16),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Semantics(
                button: true,
                label: '打开全屏主题预览',
                child: InkWell(
                  key: const ValueKey('workshop-preview-thumbnail'),
                  borderRadius: BorderRadius.circular(19),
                  onTap: () => _showFullscreenPreview(appearance),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: SizedBox(
                      width: 100,
                      height: 158.33,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: ExcludeSemantics(
                          child:
                              IgnorePointer(child: _scaledSample(appearance)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '实时预览',
                    style: typography.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (provider != null)
                    Text(
                      provider.currentAppearanceSummary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tokens.textSecondary),
                    ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final color in [
                        preview.primary,
                        preview.secondaryContainer,
                        preview.tertiaryContainer,
                        preview.surfaceContainerHighest,
                      ])
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: color,
                            border: Border.all(color: tokens.divider),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const SizedBox(width: 23, height: 18),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  FilledButton.tonalIcon(
                    onPressed: () => _showFullscreenPreview(appearance),
                    icon: const Icon(Icons.fullscreen_rounded, size: 18),
                    label: const Text('全屏预览'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategories(_WorkshopCategory category) {
    final colors = Theme.of(context).colorScheme;
    final tokens = AppThemeTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final columns = constraints.maxWidth >= 510 ? 3 : 2;
        final width = (constraints.maxWidth - (columns - 1) * gap) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in _WorkshopCategory.values)
              SizedBox(
                width: width,
                child: Semantics(
                  button: true,
                  selected: item == category,
                  child: Material(
                    color: item == category
                        ? colors.primaryContainer
                        : tokens.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(
                          color: item == category
                              ? Colors.transparent
                              : tokens.cardBorder),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: ValueKey('workshop-category-${item.name}'),
                      onTap: () => setState(() => _activeTab = item.tabs.first),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 54),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 7),
                          child: Row(
                            children: [
                              Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: item == category
                                      ? colors.primary
                                      : colors.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(item.icon,
                                    size: 17,
                                    color: item == category
                                        ? colors.onPrimary
                                        : tokens.textSecondary),
                              ),
                              const SizedBox(width: 7),
                              Flexible(
                                child: Text(
                                  item.label,
                                  style: TextStyle(
                                    fontWeight: item == category
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: item == category
                                        ? colors.onPrimaryContainer
                                        : tokens.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final appearance = _state.buildAppearance();
    final category = _WorkshopCategory.values
        .firstWhere((item) => item.tabs.contains(_activeTab));
    final canApply = context.watch<ThemeProvider?>() != null &&
        !_exporting &&
        !_savingDraft &&
        !_loadingStartPoints &&
        _editedGroups(appearance).isNotEmpty;

    return PopScope(
      canPop: _forceAllowPop || (!_draftSaveFailed && !_exporting),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _exporting) return;
        if (_draftSaveFailed) {
          unawaited(_confirmDiscardOnSaveFailure());
        }
      },
      child: GlobalBackgroundWrapper(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            titleSpacing: 8,
            title: const Text('主题设置'),
            actions: [
              FilledButton(
                key: const ValueKey('workshop-apply'),
                onPressed: canApply ? () => _runPackAction('apply') : null,
                child: const Text('应用'),
              ),
              PopupMenuButton<String>(
                enabled: !_exporting && !_loadingStartPoints,
                tooltip: '主题设置选项',
                onSelected: (action) {
                  if (action == 'start') {
                    _showStartPointMenu();
                  } else {
                    Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: action == 'settings'
                          ? widget.deviceSettingsBuilder!
                          : (_) => const ThemeCreationGuideScreen(),
                    ));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'start', child: Text('切换起点')),
                  const PopupMenuItem(value: 'guide', child: Text('制作指南')),
                  if (widget.deviceSettingsBuilder != null)
                    const PopupMenuItem(
                        value: 'settings', child: Text('设备外观偏好')),
                ],
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  children: [
                    if (_exporting || _loadingStartPoints)
                      LinearProgressIndicator(
                        semanticsLabel: _exporting ? '正在处理主题' : '正在读取主题与草稿',
                      ),
                    if (_draftSaveFailed || _bannerMessage != null)
                      Material(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(_bannerMessage ?? '草稿未保存'),
                                ),
                              ),
                              if (_draftSaveFailed)
                                TextButton(
                                  key: const ValueKey('workshop-draft-retry'),
                                  onPressed:
                                      _savingDraft ? null : _saveDraftNow,
                                  child: const Text('重试'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: AbsorbPointer(
                        absorbing: _exporting,
                        child: SingleChildScrollView(
                          key: const ValueKey('workshop-scroll'),
                          padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildPreviewCard(appearance),
                              const SizedBox(height: 10),
                              _buildCategories(category),
                              const SizedBox(height: 10),
                              if (category != _WorkshopCategory.packages)
                                Wrap(
                                  spacing: 6,
                                  children: [
                                    for (final mode in [
                                      Brightness.light,
                                      Brightness.dark
                                    ])
                                      ChoiceChip(
                                        label: Text(mode == Brightness.light
                                            ? '浅色'
                                            : '深色'),
                                        selected: _brightness == mode,
                                        onSelected: (_) =>
                                            _selectBrightness(mode),
                                      ),
                                  ],
                                ),
                              if (category.tabs.length > 1)
                                Wrap(
                                  spacing: 6,
                                  children: [
                                    for (final tab in category.tabs)
                                      ChoiceChip(
                                        key: ValueKey(
                                            'workshop-tab-${tab.name}'),
                                        label: Text(tab.label),
                                        selected: _activeTab == tab,
                                        onSelected: (_) =>
                                            setState(() => _activeTab = tab),
                                      ),
                                  ],
                                ),
                              SizedBox(key: _editorAnchor, height: 8),
                              AppCardSurface(
                                key: ValueKey(
                                    'workshop-editor-${_activeTab.name}'),
                                decoration: BoxDecoration(
                                  color: AppThemeTokens.of(context).card,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: _buildActiveTabEditor(appearance),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActiveTabEditor(ThemeAppearance appearance) {
    switch (_activeTab) {
      case WorkshopTab.colors:
        return _buildColorsEditor();
      case WorkshopTab.courses:
        return _buildCoursesEditor();
      case WorkshopTab.wallpapers:
        return _buildWallpapersEditor();
      case WorkshopTab.material:
        return _buildMaterialEditor();
      case WorkshopTab.layout:
        return _buildLayoutEditor();
      case WorkshopTab.decoration:
        return _buildDecorationEditor();
      case WorkshopTab.icons:
        return _buildIconsEditor();
      case WorkshopTab.font:
        return _buildFontEditor();
      case WorkshopTab.launcherIcon:
        return _buildLauncherIconEditor();
      case WorkshopTab.widgets:
        return ThemeWorkshopWidgetPreviewPanel(appearance: appearance);
      case WorkshopTab.packages:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('workshop-export-button'),
              onPressed: _exporting ? null : _openExportSheet,
              icon: const Icon(Icons.ios_share_outlined),
              label: const Text('导出编辑中的主题'),
            ),
            const ThemeSection(),
          ],
        );
    }
  }

  void _changePalette(VoidCallback change) {
    final variant = _currentVariant;
    final defaults = AppPalette.defaults(_brightness).toJson();
    final before = variant.effectiveTokens(_brightness);
    _mutate(() {
      // 默认外观以完整色板进入预览。第一次换色时交给种子色重新推导。
      if (defaults.entries.every((entry) => before[entry.key] == entry.value)) {
        variant.overrides.clear();
      }
      change();
    });
  }

  Widget _buildColorsEditor() {
    final v = _currentVariant;
    final tokens = v.effectiveTokens(_brightness);
    final issues = ThemeResolver.checkVariant(
      brightness: _brightness,
      tokens: tokens,
      coursePalette: v.coursePalette,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${_brightness == Brightness.light ? '浅色' : '深色'}种子色与方案',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (v.overrides.isNotEmpty)
              TextButton(
                onPressed: () => _mutate(() => v.overrides.clear()),
                child: const Text('清空覆盖项'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in _seedPresets)
              ActionChip(
                avatar: CircleAvatar(
                  backgroundColor: ThemeContrast.parseColor(preset.$1),
                ),
                label: Text(preset.$2),
                onPressed: () {
                  _seedHexController.text = preset.$1;
                  _changePalette(() => v.seedColor = preset.$1);
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('workshop-seed-hex-input'),
                controller: _seedHexController,
                decoration: const InputDecoration(
                  labelText: '种子色 HEX (#RRGGBB)',
                  isDense: true,
                ),
                onSubmitted: (raw) {
                  final parsed = ThemeResolver.tryParseHex(raw);
                  if (parsed != null) {
                    final hex = ThemeResolver.formatHex(parsed);
                    _seedHexController.text = hex;
                    _changePalette(() => v.seedColor = hex);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () {
                final parsed =
                    ThemeResolver.tryParseHex(_seedHexController.text);
                if (parsed != null) {
                  final hex = ThemeResolver.formatHex(parsed);
                  _seedHexController.text = hex;
                  _changePalette(() => v.seedColor = hex);
                }
              },
              child: const Text('应用种子色'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final variantName in const [
              'tonalSpot',
              'neutral',
              'vibrant',
              'expressive',
              'fidelity',
              'content',
            ])
              ChoiceChip(
                label: Text(variantName),
                selected: v.schemeVariant == variantName,
                onSelected: (_) =>
                    _changePalette(() => v.schemeVariant = variantName),
              ),
          ],
        ),
        const SizedBox(height: 14),
        for (final (label, key) in const [
          ('版块标签底色', 'feedSectionSurface'),
          ('标签文字颜色', 'tagText'),
        ])
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              radius: 11,
              backgroundColor: ThemeContrast.parseColor(tokens[key]!),
            ),
            title: Text(label),
            subtitle: Text(tokens[key]!),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: () => _editTokenHex(key, tokens[key]!),
          ),
        const SizedBox(height: 8),
        // 对比度检查面板
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: issues.isEmpty
                ? Colors.green.withValues(alpha: 0.1)
                : Theme.of(context)
                    .colorScheme
                    .errorContainer
                    .withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    issues.isEmpty
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 18,
                    color: issues.isEmpty
                        ? Colors.green.shade700
                        : Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      issues.isEmpty
                          ? '当前模式对比度全部达标'
                          : '${issues.length} 项对比度未达标',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (issues.isNotEmpty)
                    FilledButton.tonal(
                      key: const ValueKey('workshop-contrast-autofix'),
                      onPressed: () {
                        final fixed = ThemeResolver.autoFixVariant(
                          brightness: _brightness,
                          tokens: tokens,
                          coursePalette: v.coursePalette,
                        );
                        _mutate(() {
                          v.overrides.addAll(fixed.changedOverrides);
                          v.coursePalette = fixed.coursePalette;
                        });
                      },
                      child: const Text('自动修正'),
                    ),
                ],
              ),
              for (final issue in issues)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '• ${issue.foreground} / ${issue.background}：${issue.ratio.toStringAsFixed(2)}:1（要求 ≥ ${issue.minimum}:1）',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          initiallyExpanded: _advancedTokensExpanded,
          onExpansionChanged: (e) =>
              setState(() => _advancedTokensExpanded = e),
          tilePadding: EdgeInsets.zero,
          title: Text('高级 Token 覆盖（已覆盖 ${v.overrides.length} 项）'),
          children: [
            for (final entry in tokens.entries)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                selected: _highlightedToken == entry.key,
                leading: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: ThemeContrast.parseColor(entry.value),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                ),
                title: Text(entry.key, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  v.overrides.containsKey(entry.key)
                      ? '${entry.value}（手动覆盖）'
                      : '${entry.value}（自动推导）',
                  style: const TextStyle(fontSize: 11.5),
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    if (v.overrides.containsKey(entry.key))
                      IconButton(
                        tooltip: '重置此 Token',
                        icon: const Icon(Icons.restart_alt, size: 18),
                        onPressed: () =>
                            _mutate(() => v.overrides.remove(entry.key)),
                      ),
                    IconButton(
                      tooltip: '编辑 HEX',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => _editTokenHex(entry.key, entry.value),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _editTokenHex(String tokenKey, String currentHex) async {
    final allowAlpha = ThemeResolver.translucentTokens.contains(tokenKey);
    final ctrl = TextEditingController(text: currentHex);
    final nextHex = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text('编辑 $tokenKey'),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            labelText: allowAlpha ? '#RRGGBB 或 #AARRGGBB' : '#RRGGBB',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final parsed =
                  ThemeResolver.tryParseHex(ctrl.text, allowAlpha: allowAlpha);
              if (parsed != null) {
                Navigator.of(ctx).pop(
                  ThemeResolver.formatHex(parsed, allowAlpha: allowAlpha),
                );
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (nextHex != null && mounted) {
      _mutate(() => _currentVariant.overrides[tokenKey] = nextHex);
    }
  }

  Widget _buildCoursesEditor() {
    final v = _currentVariant;
    final tokens = v.effectiveTokens(_brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: () {
                final generated = ThemeResolver.generateCoursePalette(
                  seedColor: ThemeContrast.parseColor(v.seedColor),
                  brightness: _brightness,
                  background: ThemeContrast.parseColor(tokens['background']!),
                  courseCardText:
                      ThemeContrast.parseColor(tokens['courseCardText']!),
                );
                _mutate(() => v.coursePalette = generated);
              },
              icon: const Icon(Icons.auto_awesome_outlined, size: 18),
              label: const Text('从种子色生成 8 色'),
            ),
            OutlinedButton.icon(
              onPressed: v.coursePalette.length >= 12
                  ? null
                  : () => _mutate(() => v.coursePalette.add('#26A69A')),
              icon: const Icon(Icons.add, size: 18),
              label: Text('新增颜色 (${v.coursePalette.length}/12)'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < v.coursePalette.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: ThemeContrast.parseColor(v.coursePalette[i]),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            title: Text('课程色 ${i + 1} · ${v.coursePalette[i]}'),
            trailing: Wrap(
              spacing: 4,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () async {
                    final ctrl =
                        TextEditingController(text: v.coursePalette[i]);
                    final res = await showAppDialog<String>(
                      context: context,
                      builder: (ctx) => AppAlertDialog(
                        title: Text('修改课程色 ${i + 1}'),
                        content: TextField(
                          controller: ctrl,
                          decoration:
                              const InputDecoration(labelText: '#RRGGBB'),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () {
                              final p = ThemeResolver.tryParseHex(ctrl.text);
                              if (p != null) {
                                Navigator.of(ctx)
                                    .pop(ThemeResolver.formatHex(p));
                              }
                            },
                            child: const Text('保存'),
                          ),
                        ],
                      ),
                    );
                    ctrl.dispose();
                    if (res != null && mounted) {
                      _mutate(() => v.coursePalette[i] = res);
                    }
                  },
                ),
                if (v.coursePalette.length > 5)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _mutate(() => v.coursePalette.removeAt(i)),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildWallpapersEditor() {
    final v = _currentVariant;
    final slotData = v.wallpapers[_wallpaperSlot];

    Future<void> pickWall({required bool landscape}) async {
      final draft = _state;
      final slot = _wallpaperSlot;
      final brightness = _brightness;
      try {
        final raw = await _pickRawFile(
          'wallpaper_${slot}_${landscape ? 'landscape' : 'portrait'}',
          allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
        );
        if (raw == null || !mounted) return;
        await ThemePackCodec.validateLocalImageFile(
          raw,
          ThemeAssetKind.wallpaper,
        );
        final copied = await _draftStore.copyAssetIntoDraft(
          draft.draftId,
          raw,
          'wallpaper_${ThemeWorkshopStateData.newUuid()}${path.extension(raw)}',
        );
        if (!mounted || !identical(draft, _state)) return;
        _mutate(() {
          final current = Map<String, dynamic>.from(
            v.wallpapers[slot] ??
                {
                  'portrait': copied,
                  'fit': 'cover',
                  'focalX': 0.5,
                  'focalY': 0.5,
                  'blur': 0.0,
                  'scrim': brightness == Brightness.dark ? 0.35 : 0.0,
                },
          );
          current[landscape ? 'landscape' : 'portrait'] = copied;
          v.wallpapers[slot] = current;
        });
      } on ThemePackError catch (e) {
        if (mounted) setState(() => _bannerMessage = e.message);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final item in const [
              ('global', '全局壁纸'),
              ('home', '首页壁纸'),
              ('schedule', '课表壁纸'),
              ('me', '我的壁纸'),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: _wallpaperSlot == item.$1,
                onSelected: (_) => setState(() => _wallpaperSlot = item.$1),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => pickWall(landscape: false),
              icon: const Icon(Icons.image_outlined, size: 18),
              label: Text(slotData == null ? '选择竖屏图' : '更换竖屏图'),
            ),
            if (slotData != null)
              OutlinedButton.icon(
                onPressed: () => pickWall(landscape: true),
                icon: const Icon(Icons.stay_current_landscape, size: 18),
                label: Text(
                  slotData['landscape'] == null ? '添加横屏图' : '更换横屏图',
                ),
              ),
            if (slotData != null)
              TextButton(
                onPressed: () =>
                    _mutate(() => v.wallpapers[_wallpaperSlot] = null),
                child: const Text('清空此槽位'),
              ),
            if (_brightness == Brightness.dark)
              TextButton.icon(
                key: const ValueKey('workshop-copy-light-wallpapers'),
                onPressed: () => _mutate(() {
                  _state.dark.wallpapers = {
                    for (final entry in _state.light.wallpapers.entries)
                      entry.key: entry.value == null
                          ? null
                          : Map<String, dynamic>.from(entry.value!),
                  };
                }),
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('复制浅色壁纸设置'),
              ),
          ],
        ),
        if (slotData != null) ...[
          const SizedBox(height: 10),
          ThemeImageAdjustmentsEditor(
            settings: slotData,
            onChanged: (updated) =>
                _mutate(() => v.wallpapers[_wallpaperSlot] = updated),
          ),
        ],
      ],
    );
  }

  Widget _buildMaterialEditor() {
    final v = _currentVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('全局圆角档位'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in const [
              ('compact', '紧凑'),
              ('standard', '标准'),
              ('rounded', '圆润'),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: _state.shape == item.$1,
                onSelected: (_) => _mutate(() => _state.shape = item.$1),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text('组件底面不透明度 ${(v.componentOpacity * 100).round()}%'),
        Slider(
          value: v.componentOpacity.clamp(0.75, 1.0),
          min: 0.75,
          max: 1.0,
          divisions: 25,
          onChanged: (val) => _mutate(
            () => v.componentOpacity = (val * 100).round() / 100,
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('开启卡片毛玻璃'),
          value: v.frostedEnabled,
          onChanged: (on) => _mutate(() {
            v.frostedEnabled = on;
            if (on && v.frostedStrength == 0) v.frostedStrength = 0.5;
          }),
        ),
        if (v.frostedEnabled) ...[
          Text('毛玻璃强度 ${(v.frostedStrength * 100).round()}%'),
          Slider(
            value: v.frostedStrength.clamp(0.0, 1.0),
            min: 0.0,
            max: 1.0,
            divisions: 20,
            onChanged: (val) => _mutate(
              () => v.frostedStrength = (val * 100).round() / 100,
            ),
          ),
        ],
        const Divider(height: 24),
        Text('内容卡片描边与阴影', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        ThemeCardStyleEditor(
          cardStyle: v.cardStyle,
          onChanged: (next) => _mutate(() => v.cardStyle = next),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => _mutate(() {
              v.componentOpacity = 1.0;
              v.frostedEnabled = false;
              v.frostedStrength = 0.0;
              v.cardStyle = null;
            }),
            child: const Text('重置当前明暗材质'),
          ),
        ),
      ],
    );
  }

  Widget _buildLayoutEditor() {
    final rawSlot = _state.layout[_headerSlot];
    final slotLabel = switch (_headerSlot) {
      'campus' => '校园',
      'me' => '我的',
      _ => '首页',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in const [
              ('home', '首页页头'),
              ('campus', '校园页头'),
              ('me', '我的页头'),
            ])
              ChoiceChip(
                label: Text(s.$2),
                selected: _headerSlot == s.$1,
                onSelected: (_) => setState(() => _headerSlot = s.$1),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ThemeHeaderLayoutEditor(
          slotLabel: slotLabel,
          rawLayout: rawSlot,
          onChanged: (next) => _mutate(() {
            if (next == null) {
              _state.layout.remove(_headerSlot);
            } else {
              _state.layout[_headerSlot] = next;
            }
          }),
        ),
        if (_state.layout.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _mutate(() => _state.layout.clear()),
              child: const Text('重置全部页头布局'),
            ),
          ),
      ],
    );
  }

  Widget _buildDecorationEditor() {
    final v = _currentVariant;
    final slotLabel = switch (_headerSlot) {
      'campus' => '校园',
      'me' => '我的',
      _ => '首页',
    };
    final layoutSpec =
        ThemeHeaderLayoutSpec.fromMap(_state.layout[_headerSlot]);

    Future<String?> pickDecoAsset(ThemeAssetKind kind) async {
      try {
        final raw = await _pickRawFile(
          'deco_${_headerSlot}_${kind.name}',
          allowedExtensions: kind == ThemeAssetKind.sticker
              ? const ['png', 'webp']
              : const ['png', 'jpg', 'jpeg', 'webp'],
        );
        if (raw == null || !mounted) return null;
        await ThemePackCodec.validateLocalImageFile(raw, kind);
        return await _draftStore.copyAssetIntoDraft(
          _state.draftId,
          raw,
          'deco_${_brightness.name}_${_headerSlot}_${DateTime.now().microsecondsSinceEpoch}${path.extension(raw)}',
        );
      } on ThemePackError catch (e) {
        if (mounted) setState(() => _bannerMessage = e.message);
        return null;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in const [
              ('home', '首页装饰'),
              ('campus', '校园装饰'),
              ('me', '我的装饰'),
            ])
              ChoiceChip(
                label: Text(s.$2),
                selected: _headerSlot == s.$1,
                onSelected: (_) => setState(() => _headerSlot = s.$1),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ThemeHeaderDecorationEditor(
          slot: _headerSlot,
          slotLabel: slotLabel,
          layoutSpec: layoutSpec,
          decoration: v.decorations[_headerSlot],
          assetResolver: _resolveLocalImage,
          onPickHeaderBackground: () => pickDecoAsset(ThemeAssetKind.header),
          onPickSticker: () => pickDecoAsset(ThemeAssetKind.sticker),
          onChanged: (next) => _mutate(() => v.decorations[_headerSlot] = next),
        ),
      ],
    );
  }

  Widget _buildIconsEditor() {
    Future<void> pickNavIcon(String slot, String iconState) async {
      final draft = _state;
      try {
        final raw = await _pickRawFile(
          'nav_${slot}_$iconState',
          allowedExtensions: const ['png', 'webp', 'jpg', 'jpeg'],
        );
        if (raw == null || !mounted) return;
        final croppedPng = await Isolate.run(() async {
          final bytes = await File(raw).readAsBytes();
          final decoded = img.decodeImage(bytes);
          if (decoded == null) return null;
          final side = math.min(decoded.width, decoded.height);
          final square = img.copyCrop(
            decoded,
            x: (decoded.width - side) ~/ 2,
            y: (decoded.height - side) ~/ 2,
            width: side,
            height: side,
          );
          final resized = img.copyResize(square, width: 192, height: 192);
          return Uint8List.fromList(img.encodePng(resized));
        });
        if (croppedPng == null) {
          throw const ThemePackError('theme_image_invalid', 'bottomNav.icons');
        }
        final savedPath = await _draftStore.writeAssetBytes(
          draft.draftId,
          'nav_${ThemeWorkshopStateData.newUuid()}.png',
          croppedPng,
        );
        if (!mounted || !identical(draft, _state)) return;
        _mutate(() {
          final existing = _state.navIcons[slot];
          _state.navIcons[slot] = {
            'normal': iconState == 'normal'
                ? savedPath
                : (existing?['normal'] ?? savedPath),
            'selected': iconState == 'selected'
                ? savedPath
                : (existing?['selected'] ?? savedPath),
          };
        });
      } on ThemePackError catch (e) {
        if (mounted) setState(() => _bannerMessage = e.message);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('底栏样式'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('沿用用户设置'),
              selected: _state.bottomNavStyle == null,
              onSelected: (_) => _mutate(() => _state.bottomNavStyle = null),
            ),
            for (final item in const [
              ('normal', '标准底栏'),
              ('floating', '悬浮底栏'),
              ('liquid_glass', '液态玻璃'),
            ])
              ChoiceChip(
                label: Text(item.$2),
                selected: _state.bottomNavStyle == item.$1,
                onSelected: (_) =>
                    _mutate(() => _state.bottomNavStyle = item.$1),
              ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('图标着色模式'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('单色剪影 (template)'),
              selected: _state.iconTint == 'template',
              onSelected: (_) => _mutate(() => _state.iconTint = 'template'),
            ),
            ChoiceChip(
              label: const Text('保留原色 (original)'),
              selected: _state.iconTint == 'original',
              onSelected: (_) => _mutate(() => _state.iconTint = 'original'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          '导航图标槽位（选图后自动居中裁为正方形并缩放至 192×192 PNG）',
          style: TextStyle(fontSize: 12),
        ),
        for (final item in const [
          ('home', '首页'),
          ('market', '集市'),
          ('schedule', '课表'),
          ('campus', '校园'),
          ('me', '我'),
        ])
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(item.$2),
            subtitle: Text(
              _state.navIcons[item.$1] == null ? '使用系统默认图标' : '已设置常态与选中态图标',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Wrap(
              spacing: 6,
              children: [
                OutlinedButton(
                  onPressed: () => pickNavIcon(item.$1, 'normal'),
                  child: const Text('常态'),
                ),
                OutlinedButton(
                  onPressed: () => pickNavIcon(item.$1, 'selected'),
                  child: const Text('选中'),
                ),
                if (_state.navIcons[item.$1] != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () =>
                        _mutate(() => _state.navIcons[item.$1] = null),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFontEditor() {
    Future<void> pickFontFile({required bool bold}) async {
      final draft = _state;
      try {
        final raw = await _pickRawFile(
          bold ? 'font_bold' : 'font_regular',
          allowedExtensions: const ['ttf', 'otf'],
        );
        if (raw == null || !mounted) return;
        final bytes = await File(raw).readAsBytes();
        if (bytes.isEmpty || bytes.length > 24 * 1024 * 1024) {
          throw const ThemePackError('theme_font_invalid', 'font');
        }
        final copied = await _draftStore.copyAssetIntoDraft(
          draft.draftId,
          raw,
          'font_${ThemeWorkshopStateData.newUuid()}${path.extension(raw)}',
        );
        if (!mounted || !identical(draft, _state)) return;
        final candidateFont = <String, dynamic>{
          'name': _state.font?['name'] ??
              path.basenameWithoutExtension(raw).takeRunes(30),
          'regular': bold ? (_state.font?['regular'] ?? copied) : copied,
          if (bold)
            'bold': copied
          else if (_state.font?['bold'] != null)
            'bold': _state.font!['bold'],
          'license': _state.font?['license'] ?? 'OFL-1.1',
        };
        final loaded = await ThemeFontRegistry.ensureLoaded(candidateFont);
        if (loaded == null) {
          throw const ThemePackError('theme_font_invalid', 'font');
        }
        if (!mounted || !identical(draft, _state)) return;
        _mutate(() => _state.font = candidateFont);
      } on ThemePackError catch (e) {
        if (mounted) setState(() => _bannerMessage = e.message);
      }
    }

    final fontMap = _state.font;
    final resolvedFamily = ThemeFontRegistry.resolvedFamilyFor(
      _state.buildAppearance().group(ThemeGroup.font),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => pickFontFile(bold: false),
              icon: const Icon(Icons.font_download_outlined, size: 18),
              label: Text(fontMap == null ? '选择常规体 (.ttf/.otf)' : '更换常规体'),
            ),
            if (fontMap != null)
              OutlinedButton.icon(
                onPressed: () => pickFontFile(bold: true),
                icon: const Icon(Icons.format_bold, size: 18),
                label: Text(fontMap['bold'] == null ? '添加粗体（可选）' : '更换粗体'),
              ),
            if (fontMap != null)
              TextButton(
                onPressed: () => _mutate(() => _state.font = null),
                child: const Text('移除自定义字体'),
              ),
          ],
        ),
        if (fontMap != null) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: fontMap['license'] as String? ?? 'OFL-1.1',
            decoration: const InputDecoration(labelText: '字体开源/版权许可'),
            items: const [
              DropdownMenuItem(value: 'OFL-1.1', child: Text('SIL OFL-1.1')),
              DropdownMenuItem(value: 'Apache-2.0', child: Text('Apache-2.0')),
              DropdownMenuItem(value: 'CC0-1.0', child: Text('CC0-1.0')),
              DropdownMenuItem(
                value: 'author-owned',
                child: Text('作者本人拥有版权 (author-owned)'),
              ),
            ],
            onChanged: (lic) {
              if (lic != null) {
                _mutate(() => _state.font = {...fontMap, 'license': lic});
              }
            },
          ),
        ],
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppThemeTokens.of(context).surfaceMuted,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '标题样例：沈阳理工大学校园生活',
                style: TextStyle(
                  fontFamily: resolvedFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '正文样例：春风拂过浑河南岸，今天上午八点在主教 302 教室上高等数学。',
                style: TextStyle(fontFamily: resolvedFamily, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                '数字与英文：2026-10-18 · Room B204 · GPA 3.92',
                style: TextStyle(fontFamily: resolvedFamily, fontSize: 13.5),
              ),
              const SizedBox(height: 6),
              const Text(
                '等宽对照（保持不变）：0x147C72 · SHA-256',
                style: TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLauncherIconEditor() {
    Future<void> pickCustomLauncher() async {
      try {
        final raw = await _pickRawFile(
          'launcher_custom',
          allowedExtensions: const ['png', 'webp'],
        );
        if (raw == null || !mounted) return;
        await ThemePackCodec.validateLocalImageFile(
          raw,
          ThemeAssetKind.launcher,
        );
        final copied = await _draftStore.copyAssetIntoDraft(
          _state.draftId,
          raw,
          'launcher_custom${path.extension(raw)}',
        );
        if (!mounted) return;
        _mutate(() => _state.customLauncherIconPath = copied);
      } on ThemePackError catch (e) {
        if (mounted) setState(() => _bannerMessage = e.message);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('此处编辑随主题包分享的图标。本机桌面图标可在主题包分类中单独设置。'),
        const SizedBox(height: 8),
        const Text('内置备选桌面图标'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('不指定'),
              selected: _state.builtinLauncherIcon == null,
              onSelected: (_) =>
                  _mutate(() => _state.builtinLauncherIcon = null),
            ),
            for (final spec in LauncherIconService.builtinIcons)
              ChoiceChip(
                label: Text('${spec.name} (${spec.id})'),
                selected: _state.builtinLauncherIcon == spec.id,
                onSelected: (_) =>
                    _mutate(() => _state.builtinLauncherIcon = spec.id),
              ),
          ],
        ),
        const SizedBox(height: 14),
        const Text('自定义桌面快捷方式图标（432–1024px 正方形不透明 PNG/WebP）'),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: pickCustomLauncher,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: Text(
                _state.customLauncherIconPath == null ? '选择自定义图标' : '更换自定义图标',
              ),
            ),
            if (_state.customLauncherIconPath != null)
              TextButton(
                onPressed: () =>
                    _mutate(() => _state.customLauncherIconPath = null),
                child: const Text('移除自定义图标'),
              ),
          ],
        ),
        if (_state.customLauncherIconPath != null) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              Column(
                children: [
                  ClipOval(
                    child: Image.file(
                      File(_state.customLauncherIconPath!),
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('圆形遮罩', style: TextStyle(fontSize: 11.5)),
                ],
              ),
              Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(15),
                    child: Image.file(
                      File(_state.customLauncherIconPath!),
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('圆角方形遮罩', style: TextStyle(fontSize: 11.5)),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }
}

extension on String {
  String takeRunes(int max) {
    final r = runes.toList();
    return r.length <= max ? this : String.fromCharCodes(r.take(max));
  }
}

/// 静态“主题制作指南”页面（制作细则第 1–5 节）。
class ThemeCreationGuideScreen extends StatelessWidget {
  const ThemeCreationGuideScreen({super.key});

  static const _sections = [
    (
      '1. 制作流程',
      '1) 选定种子色推导全套 Token，在明暗两套下分别检查首页与课表；\n'
          '2) 生成课程色板，确认相邻课程色相差距清晰；\n'
          '3) 按需配置全局及首页、课表、我的壁纸，调整焦点、亮度/对比度/饱和度、模糊与遮罩；\n'
          '4) 调整组件不透明度、毛玻璃、全局圆角及卡片描边与阴影；\n'
          '5) 为首页、校园、我选择标准/紧凑/沉浸页头模板与最多 5 张透明贴纸；\n'
          '6) 确认对比度面板全绿，并在 1.5 倍字号下检查九个首批页面与异常状态后再导出。'
    ),
    (
      '2. 配色细则',
      '• 满足契约全部对比度阈值（正文 4.5:1，导航 3.0:1，课程块 0.45 合成后 4.5:1）；\n'
          '• background、surface、card 在 HCT 空间的色度不超过 16，避免大面积高饱和疲劳；\n'
          '• 浅色 background 色调建议 ≥90（推荐微暖白或微冷白），深色色调建议 ≤12；\n'
          '• 主色与危险色 #E54848 色相差至少 20°，避免普通按钮像警告删除操作。'
    ),
    (
      '3. 壁纸、页头背景与贴纸细则',
      '• 壁纸推荐竖屏 1080×2340，长边至多 4096；不能含文字、水印、二维码或联系方式；\n'
          '• 课表建议低对比画面并设置 blur 4–8、scrim ≥0.2；深色模式若共用浅色图，scrim 至少 0.35；\n'
          '• 页头背景与贴纸只出现在独立装饰区，PNG/WebP 贴纸保留透明边缘，不得画假按钮或假系统弹窗。'
    ),
    (
      '4. 图标与桌面图标细则',
      '• 底栏图标采用 192×192 透明画布（主体在中间 144×144），五个槽位要么全换、要么只换首页；常态与选中态必须有清晰区别；\n'
          '• 自定义桌面快捷方式图标推荐 1024×1024 不透明画布，主体放在中间 66% 安全圆内，不得模仿系统或其他 App 图标。'
    ),
    (
      '5. 字体细则',
      '• 仅接受 OFL-1.1、Apache-2.0、CC0-1.0 或作者本人拥有版权的字体；\n'
          '• 商城投稿要求可打印 ASCII 100% 覆盖、GB2312 一级汉字（3755 字）覆盖率 ≥99%，单文件 ≤24MB；\n'
          '• 正文 14sp 笔画清楚，1.5 倍字号下不出现溢出或截断。'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('主题制作指南')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _sections.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final (title, body) = _sections[index];
              return AppCardSurface(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppThemeTokens.of(context).card,
                  borderRadius: BorderRadius.circular(AppShape.of(context).lg),
                  border:
                      Border.all(color: AppThemeTokens.of(context).cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(body, style: const TextStyle(height: 1.5)),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
