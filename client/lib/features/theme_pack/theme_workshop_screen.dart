import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/theme_provider.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_theme_tokens.dart';
import '../../widgets/app_bottom_sheet.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/global_background_wrapper.dart';
import '../../widgets/opacity_safe_backdrop_filter.dart';
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
  colors('颜色', '种子色、配色方案与课表色板', Icons.colorize_outlined,
      [WorkshopTab.colors, WorkshopTab.courses]),
  wallpapers(
      '背景', '各页面壁纸、模糊与遮罩', Icons.wallpaper_outlined, [WorkshopTab.wallpapers]),
  material(
      '卡片材质', '透明度、毛玻璃与描边阴影', Icons.layers_outlined, [WorkshopTab.material]),
  cards('页头装饰', '页头布局、贴纸与装饰图', Icons.dashboard_customize_outlined,
      [WorkshopTab.layout, WorkshopTab.decoration]),
  navigation('底栏导航', '底栏图标与选中样式', Icons.space_bar_rounded, [WorkshopTab.icons]),
  typography('字体', '标题与正文字体', Icons.text_fields_rounded, [WorkshopTab.font]),
  desktop('桌面组件', '桌面图标与小部件', Icons.widgets_outlined,
      [WorkshopTab.launcherIcon, WorkshopTab.widgets]),
  packages(
      '主题包', '导入、导出与管理主题包', Icons.inventory_2_outlined, [WorkshopTab.packages]);

  const _WorkshopCategory(this.label, this.description, this.icon, this.tabs);
  final String label;
  final String description;
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
          .clamp(0.0, 1.0),
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
          seedColor: seed, brightness: brightness);
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
      bottomNavStyle: 'liquid_glass',
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
      final effectivePalette = appearance.buildTheme(brightness).extension<AppPalette>()!;
      final targetTokens = effectivePalette.toJson();
      final overrides = <String, String>{
        for (final entry in targetTokens.entries)
          if (derived[entry.key] != entry.value.toUpperCase())
            entry.key: entry.value.toUpperCase(),
      };
      final palette = [
        for (final color in effectivePalette.coursePalette)
          '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
      ];

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
            .clamp(0.0, 1.0);
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
        for (final slot in const ['home', 'campus', 'me', 'ornaments', 'serviceIcons']) {
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
    // 编辑现有外观时，未指定的样式继续由设备偏好决定。
    base.bottomNavStyle = nav?['style'] as String?;
    if (nav != null) {
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
        'style': bottomNavStyle ?? 'liquid_glass',
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
    bool requireContrastPass = false,
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

      final ornaments = v.decorations['ornaments'];
      final serviceIcons = v.decorations['serviceIcons'];
      Map<String, dynamic>? decosOut;
      if (includes(ThemeGroup.decoration) &&
          const ['home', 'campus', 'me'].any((slot) => v.decorations[slot] != null)) {
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
        if (includes(ThemeGroup.decoration) && ornaments != null)
          'ornaments': {
            for (final entry in ornaments.entries)
              entry.key: {
                ...Map<String, dynamic>.from(entry.value as Map),
                'image': await registerAsset(entry.value['image'] as String, 'decorations'),
              },
          },
        if (includes(ThemeGroup.decoration) && serviceIcons != null)
          'serviceIcons': {
            for (final entry in serviceIcons.entries)
              entry.key: await registerAsset(entry.value as String, 'icons'),
          },
      };
    }

    final lightMap = await buildManifestVariant(Brightness.light);
    final darkMap = await buildManifestVariant(Brightness.dark);

    Map<String, dynamic>? bottomNavOut;
    final hasAnyNavIcon = navIcons.values.any((pair) => pair != null);
    if (includes(ThemeGroup.navigation) &&
        (iconTint != 'template' || hasAnyNavIcon || bottomNavStyle != null)) {
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

    Future<Uint8List> previewBytes(
      Uint8List? rendered,
      Map<String, dynamic> variant,
    ) =>
        rendered == null
            ? _fallbackPreviewJpeg(variant)
            : Isolate.run(() => ThemeAppearanceExporter.encodePreviewJpeg(
                img.decodePng(rendered)!));
    rawFiles['preview/light.jpg'] = await previewBytes(renderedLightPng, lightMap);
    rawFiles['preview/dark.jpg'] = await previewBytes(renderedDarkPng, darkMap);

    final safeVersion =
        RegExp(r'^\d+\.\d+\.\d+$').hasMatch(appVersion) ? appVersion : '1.0.0';
    final safeName = name.trim().isEmpty
        ? '未命名主题'
        : String.fromCharCodes(name.trim().runes.take(20));
    final safeAuthor = author.trim().isEmpty
        ? '创作者'
        : String.fromCharCodes(author.trim().runes.take(20));
    final safeDesc = String.fromCharCodes(description.trim().runes.take(200));

    final exportedLayout = ThemeAppearanceExporter.headerLayout(layout, lightMap, darkMap);
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
        'light': 'preview/light.jpg',
        'dark': 'preview/dark.jpg',
      },
      'shape': shape,
      'light': lightMap,
      'dark': darkMap,
      if (bottomNavOut != null) 'bottomNav': bottomNavOut,
      if (fontOut != null) 'font': fontOut,
      if (launcherOut != null) 'launcherIcon': launcherOut,
      if (includes(ThemeGroup.layout) && exportedLayout.isNotEmpty) 'layout': exportedLayout,
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

  static Future<Uint8List> _fallbackPreviewJpeg(Map<String, dynamic> variant) =>
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
        return ThemeAppearanceExporter.encodePreviewJpeg(canvas);
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
  final _seedHexFocus = FocusNode();

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
    _seedHexFocus.dispose();
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

  void _reloadCurrentAppearance() {
    _mutate(() {
      _state = _currentDraft(context.read<ThemeProvider>(),
          draftId: _state.draftId);
      _appliedGroups = _groupValues(_state.buildAppearance());
      _seedHexController.text = _currentVariant.seedColor;
      _highlightedToken = null;
    });
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
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('默认主题（经典）'),
                  subtitle: const Text('从主题商城上线前的原始配色与布局开始'),
                  onTap: () => Navigator.of(sheetCtx).pop('original'),
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
      if (chosen == 'original') {
        _state = ThemeWorkshopStateData.fromAppearance(
          const ThemeAppearance.originalDefault(),
          draftId: _state.draftId,
        );
      } else if (chosen == 'default') {
        _state = ThemeWorkshopStateData.fromDefault(draftId: _state.draftId);
      } else if (chosen == 'current' && provider != null) {
        _state = _currentDraft(provider, draftId: _state.draftId);
        _appliedGroups = _groupValues(_state.buildAppearance());
      } else if (chosen is InstalledTheme) {
        _state = ThemeWorkshopStateData.fromInstalled(
          chosen,
          draftId: _state.draftId,
        )..bottomNavStyle = provider?.bottomNavStyle.storageValue;
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



  Future<void> _openExportSheet() async {
    if (_exporting) return;

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
                  isExpanded: true,
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
      await _saveDraftNow();
      if (!mounted) return;
      if (applying) {
        await provider.applyEditedAppearance(appearance, groups);
        if (!mounted) return;
        setState(() => _appliedGroups = _groupValues(appearance));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('主题已应用')),
        );
        return;
      }
      final appVer = widget.appVersion ?? await _resolveAppVersion();
      if (!mounted) return;
      final (lightPng, darkPng) = await ThemeWorkshopExportStage.capture(
        context, appearance, _resolveLocalImage,
      );
      final (bytes, prepared) = await draft._exportPack(
        appVersion: appVer,
        renderedLightPng: lightPng,
        renderedDarkPng: darkPng,
        requireContrastPass: false,
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

  /// 预览手机的高宽比跟随当前屏幕，避免缩略图比真机矮胖。
  double get _phoneRatio {
    final size = MediaQuery.sizeOf(context);
    final short = math.min(size.width, size.height);
    final long = math.max(size.width, size.height);
    return short <= 0 ? 2.0 : (long / short).clamp(1.6, 2.4);
  }

  Widget _scaledSample(ThemeAppearance appearance) => FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 360,
          height: 360 * _phoneRatio,
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

  String _previewName() {
    final provider = context.read<ThemeProvider?>();
    if (provider == null) return '当前外观';
    final trial = provider.trial;
    if (trial != null) return trial.manifest.name;
    final appearance = provider.persistedAppearance;
    return appearance.singleThemeName ??
        (appearance.activeGroupSources.isEmpty ? '默认外观' : '混搭外观');
  }

  /// 主题设置页的分组面板：无描边、无主题卡片样式，只靠半透明底和圆角分段。
  /// 主题设置页的分组面板：半透明磨砂底，壁纸能透出来；不套全局卡片材质，
  /// 各面板互不重叠，共用页面背景的一次模糊采样。
  Widget _panel({
    Key? key,
    required BorderRadius radius,
    required Widget child,
    EdgeInsetsGeometry? padding,
  }) {
    return ClipRRect(
      key: key,
      borderRadius: radius,
      child: OpacitySafeBackdropFilter(
        grouped: true,
        filter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppThemeTokens.of(context).card.withValues(alpha: .4),
          ),
          child:
              padding == null ? child : Padding(padding: padding, child: child),
        ),
      ),
    );
  }

  Widget _buildPreviewCard(ThemeAppearance appearance) {
    final tokens = AppThemeTokens.of(context);
    final preview = appearance.buildTheme(_brightness).colorScheme;
    context.watch<ThemeProvider?>();
    final typography = Theme.of(context).textTheme;
    return _panel(
      radius: BorderRadius.circular(24),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => _showFullscreenPreview(appearance),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
            child: Row(
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: preview.onSurface,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Semantics(
                    button: true,
                    label: '打开全屏主题预览',
                    child: InkWell(
                      key: const ValueKey('workshop-preview-thumbnail'),
                      borderRadius: BorderRadius.circular(26),
                      onTap: () => _showFullscreenPreview(appearance),
                      child: Padding(
                        padding: const EdgeInsets.all(2.5),
                        child: SizedBox(
                          width: 76,
                          height: 76 * _phoneRatio,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(23.5),
                            child: ExcludeSemantics(
                              child: IgnorePointer(
                                  child: _scaledSample(appearance)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '预览 · ${_previewName()}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: typography.titleSmall?.copyWith(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                          color: tokens.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${_brightness == Brightness.light ? '浅色' : '深色'}'
                        ' · ${_currentVariant.schemeVariant}',
                        style: typography.bodySmall?.copyWith(
                          fontSize: 12.5,
                          color: tokens.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          for (final color in [
                            preview.primary,
                            preview.secondaryContainer,
                            preview.tertiaryContainer,
                            preview.surfaceContainerHighest,
                          ])
                            Padding(
                              padding: const EdgeInsetsDirectional.only(end: 6),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                                child: const SizedBox(width: 18, height: 18),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '调整下方设置，预览会实时更新 · 点按可全屏查看',
                        style: typography.bodySmall?.copyWith(
                          fontSize: 11.5,
                          color: tokens.textSecondary,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 选中态主色填充、未选中浅色底的小圆角块，分类网格和分段条共用。
  Widget _choiceTile({
    required Key key,
    required bool selected,
    required VoidCallback onTap,
    required Widget Function(Color foreground) builder,
    double minHeight = 52,
  }) {
    final colors = Theme.of(context).colorScheme;
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? colors.primary
            : colors.surfaceContainerHighest.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(selected ? 20 : 12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: key,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Center(
              child: builder(selected ? colors.onPrimary : tokens.textPrimary),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategories(_WorkshopCategory category) {
    return _panel(
      radius: BorderRadius.circular(22),
      padding: const EdgeInsets.all(5),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 3.0;
          final columns = constraints.maxWidth >= 510 ? 8 : 4;
          final width = (constraints.maxWidth - (columns - 1) * gap) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final item in _WorkshopCategory.values)
                SizedBox(
                  width: width,
                  child: _choiceTile(
                    key: ValueKey('workshop-category-${item.name}'),
                    selected: item == category,
                    onTap: () => setState(() => _activeTab = item.tabs.first),
                    builder: (foreground) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 7),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(item.icon, size: 19, color: foreground),
                          const SizedBox(height: 3),
                          Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: foreground,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 分组列表里的一段：首段上圆角大、末段下圆角大，中间段只留小圆角。
  BorderRadius _groupRadius({required bool first, required bool last}) {
    const outer = Radius.circular(22);
    const inner = Radius.circular(6);
    return BorderRadius.vertical(
      top: first ? outer : inner,
      bottom: last ? outer : inner,
    );
  }

  Widget _buildSectionHeader(_WorkshopCategory category, BorderRadius radius) {
    final tokens = AppThemeTokens.of(context);
    final typography = Theme.of(context).textTheme;
    return _panel(
      radius: radius,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tokens.surface.withValues(alpha: .92),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(category.icon, size: 19, color: tokens.textPrimary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.label,
                  style: typography.titleSmall?.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: tokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  category.description,
                  style: typography.bodySmall?.copyWith(
                    fontSize: 12.5,
                    color: tokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegments<T>({
    required List<T> values,
    required T selected,
    required String Function(T) label,
    IconData? Function(T)? icon,
    required Key Function(T) keyOf,
    required ValueChanged<T> onSelected,
    required BorderRadius radius,
  }) {
    return _panel(
      radius: radius,
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          for (final (index, value) in values.indexed) ...[
            if (index > 0) const SizedBox(width: 3),
            Expanded(
              child: _choiceTile(
                key: keyOf(value),
                selected: value == selected,
                minHeight: 38,
                onTap: () => onSelected(value),
                builder: (foreground) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon?.call(value) case final data?) ...[
                      Icon(data, size: 17, color: foreground),
                      const SizedBox(width: 5),
                    ],
                    Flexible(
                      child: Text(
                        label(value),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: foreground,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionGroup(
      ThemeAppearance appearance, _WorkshopCategory category) {
    final showBrightness = category != _WorkshopCategory.packages;
    final showTabs = category.tabs.length > 1;
    const middle = BorderRadius.all(Radius.circular(6));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(category, _groupRadius(first: true, last: false)),
        if (showBrightness) ...[
          const SizedBox(height: 3),
          _buildSegments<Brightness>(
            values: const [Brightness.light, Brightness.dark],
            selected: _brightness,
            label: (mode) => mode == Brightness.light ? '浅色' : '深色',
            icon: (mode) => mode == Brightness.light
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined,
            keyOf: (mode) => ValueKey('workshop-brightness-${mode.name}'),
            onSelected: _selectBrightness,
            radius: middle,
          ),
        ],
        if (showTabs) ...[
          const SizedBox(height: 3),
          _buildSegments<WorkshopTab>(
            values: category.tabs,
            selected: _activeTab,
            label: (tab) => tab.label,
            keyOf: (tab) => ValueKey('workshop-tab-${tab.name}'),
            onSelected: (tab) => setState(() => _activeTab = tab),
            radius: middle,
          ),
        ],
        SizedBox(key: _editorAnchor, height: 3),
        ..._buildEditorSegments(appearance),
      ],
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
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            scrolledUnderElevation: 0,
            toolbarHeight: 64,
            leadingWidth: 64,
            leading: Navigator.of(context).canPop()
                ? Padding(
                    padding: const EdgeInsetsDirectional.only(start: 16),
                    child: Center(
                      child: IconButton.filledTonal(
                        tooltip:
                            MaterialLocalizations.of(context).backButtonTooltip,
                        style: IconButton.styleFrom(
                          fixedSize: const Size.square(40),
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: .7),
                        ),
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded, size: 21),
                      ),
                    ),
                  )
                : null,
            centerTitle: false,
            titleSpacing: 10,
            title: Text(
              '主题设置',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontSize: 21,
                    fontWeight: FontWeight.w500,
                    color: AppThemeTokens.of(context).textPrimary,
                  ),
            ),
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
                          padding: const EdgeInsets.fromLTRB(14, 2, 14, 28),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildPreviewCard(appearance),
                              const SizedBox(height: 10),
                              _buildCategories(category),
                              const SizedBox(height: 10),
                              _buildSectionGroup(appearance, category),
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

  static const _schemeVariants = [
    ('tonalSpot', '柔和协调，系统默认'),
    ('neutral', '低饱和，接近灰调'),
    ('vibrant', '高饱和，色彩更鲜明'),
    ('expressive', '跳色更大胆'),
    ('fidelity', '尽量贴近种子色'),
    ('content', '按内容取色'),
  ];

  static final _swatchSchemes = <String, ColorScheme>{};

  /// 编辑区内的芯片、按钮和输入框统一去掉描边，改成浅色底胶囊。
  ThemeData _expressiveEditorTheme() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tonal = colors.surfaceContainerHighest.withValues(alpha: .55);
    final field = OutlineInputBorder(
      borderSide: BorderSide.none,
      borderRadius: BorderRadius.circular(14),
    );
    return theme.copyWith(
      chipTheme: theme.chipTheme.copyWith(
        side: BorderSide.none,
        shape: const StadiumBorder(),
        color: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.secondaryContainer
              : tonal,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide.none,
          backgroundColor: tonal,
          shape: const StadiumBorder(),
        ).merge(theme.outlinedButtonTheme.style),
      ),
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: tonal,
        border: field,
        enabledBorder: field,
        focusedBorder: field.copyWith(
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          side: BorderSide.none,
          backgroundColor: tonal,
          selectedBackgroundColor: colors.secondaryContainer,
        ).merge(theme.segmentedButtonTheme.style),
      ),
      switchTheme: theme.switchTheme.copyWith(
        thumbIcon: WidgetStateProperty.resolveWith(
          (states) => Icon(
            states.contains(WidgetState.selected)
                ? Icons.check_rounded
                : Icons.close_rounded,
            size: 16,
          ),
        ),
      ),
      sliderTheme: theme.sliderTheme.copyWith(
        trackHeight: 8,
        tickMarkShape: SliderTickMarkShape.noTickMark,
      ),
      expansionTileTheme: theme.expansionTileTheme.copyWith(
        shape: const Border(),
        collapsedShape: const Border(),
      ),
    );
  }

  Widget _iconTile(Widget child) {
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppThemeTokens.of(context).surface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  /// 分组列表的一行：左侧图标块，中间标题与说明，右侧取值或操作。
  Widget _settingRow({
    Key? key,
    required Widget leading,
    required String title,
    String? subtitle,
    Color? subtitleColor,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final tokens = AppThemeTokens.of(context);
    final typography = Theme.of(context).textTheme;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
      child: Row(
        children: [
          _iconTile(leading),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: typography.titleSmall?.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: tokens.textPrimary,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: typography.bodySmall?.copyWith(
                      fontSize: 12.5,
                      color: subtitleColor ?? tokens.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
    );
    if (onTap == null) return KeyedSubtree(key: key, child: content);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(key: key, onTap: onTap, child: content),
    );
  }

  Widget _rowValue(String text) {
    final tokens = AppThemeTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        Icon(Icons.chevron_right_rounded,
            size: 20, color: tokens.textSecondary),
      ],
    );
  }

  /// 种子色色块：上下两半取该种子推导出的浅色调，中心点是主色。
  Widget _seedSwatch({
    required Key key,
    required String? hex,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final page = Theme.of(context);
    final colors = page.colorScheme;
    final tokens = AppThemeTokens.of(context);
    final scheme = hex == null
        ? null
        : _swatchSchemes.putIfAbsent(
            '$hex-${page.brightness.name}',
            () => ColorScheme.fromSeed(
              seedColor: ThemeContrast.parseColor(hex),
              brightness: page.brightness,
            ),
          );
    final Widget circle;
    if (scheme == null) {
      circle = Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: tokens.surface.withValues(alpha: .92),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.add_rounded, size: 22, color: tokens.textPrimary),
      );
    } else {
      circle = SizedBox(
        width: 46,
        height: 46,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: ClipOval(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: ColoredBox(color: scheme.primaryFixed)),
                    Expanded(child: ColoredBox(color: scheme.tertiaryFixedDim)),
                  ],
                ),
              ),
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
              child: selected
                  ? Icon(Icons.check_rounded, size: 15, color: scheme.onPrimary)
                  : null,
            ),
          ],
        ),
      );
    }
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: scheme?.surfaceContainerHigh ??
            colors.surfaceContainerHighest.withValues(alpha: .55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(selected ? 26 : 18),
          side: selected
              ? BorderSide(color: colors.primary, width: 2)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: key,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 9),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                circle,
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: tokens.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _applySeedHex(String raw) {
    final parsed = ThemeResolver.tryParseHex(raw);
    if (parsed == null) return;
    final hex = ThemeResolver.formatHex(parsed);
    _seedHexController.text = hex;
    _changePalette(() => _currentVariant.seedColor = hex);
  }

  Future<void> _pickSchemeVariant() async {
    final current = _currentVariant.schemeVariant;
    final picked = await showAppModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (name, description) in _schemeVariants)
              ListTile(
                key: ValueKey('workshop-scheme-$name'),
                title: Text(name),
                subtitle: Text(description),
                trailing:
                    name == current ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(sheet).pop(name),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted && picked != current) {
      _changePalette(() => _currentVariant.schemeVariant = picked);
    }
  }

  List<Widget> _buildColorSegments() {
    final v = _currentVariant;
    final tokens = v.effectiveTokens(_brightness);
    final colors = Theme.of(context).colorScheme;
    final appTokens = AppThemeTokens.of(context);
    final seed = v.seedColor.toUpperCase();
    final isPreset = _seedPresets.any((p) => p.$1.toUpperCase() == seed);
    final tonal = colors.surfaceContainerHighest.withValues(alpha: .55);

    return [
      Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const gap = 8.0;
            final width = (constraints.maxWidth - 3 * gap) / 4;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final preset in _seedPresets)
                  SizedBox(
                    width: width,
                    child: _seedSwatch(
                      key: ValueKey('workshop-seed-${preset.$2}'),
                      hex: preset.$1,
                      label: preset.$2,
                      selected: preset.$1.toUpperCase() == seed,
                      onTap: () => _applySeedHex(preset.$1),
                    ),
                  ),
                SizedBox(
                  width: width,
                  child: _seedSwatch(
                    key: const ValueKey('workshop-seed-custom'),
                    hex: isPreset ? null : v.seedColor,
                    label: '自定义',
                    selected: !isPreset,
                    onTap: _seedHexFocus.requestFocus,
                  ),
                ),
              ],
            );
          },
        ),
      ),
      _settingRow(
        leading:
            Icon(Icons.tag_rounded, size: 19, color: appTokens.textPrimary),
        title: '种子色',
        subtitle: '输入 #RRGGBB',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 112,
              child: TextField(
                key: const ValueKey('workshop-seed-hex-input'),
                controller: _seedHexController,
                focusNode: _seedHexFocus,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: tonal,
                  hintText: '#RRGGBB',
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onSubmitted: _applySeedHex,
              ),
            ),
            IconButton(
              tooltip: '应用种子色',
              icon: const Icon(Icons.check_rounded),
              onPressed: () => _applySeedHex(_seedHexController.text),
            ),
          ],
        ),
      ),
      _settingRow(
        key: const ValueKey('workshop-scheme-variant'),
        leading:
            Icon(Icons.style_outlined, size: 19, color: appTokens.textPrimary),
        title: '色彩风格',
        trailing: _rowValue(v.schemeVariant),
        onTap: _pickSchemeVariant,
      ),
      for (final (label, key) in const [
        ('版块标签底色', 'feedSectionSurface'),
        ('标签文字颜色', 'tagText'),
      ])
        _settingRow(
          leading: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: ThemeContrast.parseColor(tokens[key]!),
              shape: BoxShape.circle,
            ),
          ),
          title: label,
          trailing: _rowValue(tokens[key]!),
          onTap: () => _editTokenHex(key, tokens[key]!),
        ),
      if (v.overrides.isNotEmpty)
        _settingRow(
          leading: Icon(Icons.restart_alt_rounded,
              size: 19, color: appTokens.textPrimary),
          title: '清空覆盖项',
          subtitle: '恢复按种子色自动推导',
          onTap: () => _mutate(() => v.overrides.clear()),
        ),
      Theme(
        data: _expressiveEditorTheme(),
        child: ExpansionTile(
          initiallyExpanded: _advancedTokensExpanded,
          onExpansionChanged: (e) =>
              setState(() => _advancedTokensExpanded = e),
          tilePadding: const EdgeInsets.fromLTRB(14, 4, 12, 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 8, 10),
          leading: _iconTile(
            Icon(Icons.tune_rounded, size: 19, color: appTokens.textPrimary),
          ),
          title: Text(
            '高级 Token 覆盖',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: appTokens.textPrimary,
            ),
          ),
          subtitle: Text(
            '已覆盖 ${v.overrides.length} 项',
            style: TextStyle(fontSize: 12.5, color: appTokens.textSecondary),
          ),
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
      ),
    ];
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

  Widget _rowIcon(IconData data) =>
      Icon(data, size: 19, color: AppThemeTokens.of(context).textPrimary);

  Widget _rowSwitch(bool value, ValueChanged<bool> onChanged) =>
      Switch(value: value, onChanged: onChanged);

  Widget _rowDivider() => Divider(
        height: 1,
        indent: 14,
        endIndent: 14,
        color: AppThemeTokens.of(context).divider.withValues(alpha: .6),
      );

  /// 共享编辑器（壁纸参数、卡片描边等）放进分组里时统一留白。
  Widget _embedded(Widget child) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: child,
      );

  /// 一段里的选项块：可带一行小标题，选中项主色填满。
  Widget _choiceGrid<T>({
    String? title,
    required List<T> values,
    required T selected,
    required String Function(T) label,
    required ValueChanged<T> onSelected,
    Key Function(T)? keyOf,
    int? columns,
  }) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: tokens.textSecondary,
                ),
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 3.0;
              final perRow = columns ?? values.length;
              final width =
                  (constraints.maxWidth - (perRow - 1) * gap) / perRow;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final value in values)
                    SizedBox(
                      width: width,
                      child: _choiceTile(
                        key: keyOf?.call(value) ??
                            ValueKey('workshop-choice-${label(value)}'),
                        selected: value == selected,
                        minHeight: 40,
                        onTap: () => onSelected(value),
                        builder: (foreground) => Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            label(value),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: foreground,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// 滑杆行：图标、标题与当前值在上，滑杆铺满整行。
  Widget _sliderRow({
    required IconData icon,
    required String title,
    String? subtitle,
    required String value,
    required Widget slider,
  }) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 38,
                child: Icon(icon, size: 22, color: tokens.textPrimary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: tokens.textPrimary,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: tokens.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                value,
                style: TextStyle(fontSize: 13.5, color: tokens.textSecondary),
              ),
            ],
          ),
          slider,
        ],
      ),
    );
  }

  Future<T?> _pickOption<T>({
    required T current,
    required List<(T, String, String?)> options,
    String keyPrefix = 'workshop-option',
  }) {
    return showAppModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (value, title, description) in options)
              ListTile(
                key: ValueKey('$keyPrefix-$value'),
                title: Text(title),
                subtitle: description == null ? null : Text(description),
                trailing:
                    value == current ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(sheet).pop(value),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildActiveTabSegments(ThemeAppearance appearance) {
    switch (_activeTab) {
      case WorkshopTab.colors:
        return _buildColorSegments();
      case WorkshopTab.courses:
        return _buildCourseSegments();
      case WorkshopTab.wallpapers:
        return _buildWallpaperSegments();
      case WorkshopTab.material:
        return _buildMaterialSegments();
      case WorkshopTab.layout:
        return _buildLayoutSegments();
      case WorkshopTab.decoration:
        return _buildDecorationSegments();
      case WorkshopTab.icons:
        return _buildIconSegments();
      case WorkshopTab.font:
        return _buildFontSegments();
      case WorkshopTab.launcherIcon:
        return _buildLauncherIconSegments();
      case WorkshopTab.widgets:
        return [
          _embedded(ThemeWorkshopWidgetPreviewPanel(appearance: appearance)),
        ];
      case WorkshopTab.packages:
        return [
          _settingRow(
            key: const ValueKey('workshop-export-button'),
            leading: _rowIcon(Icons.ios_share_outlined),
            title: '导出编辑中的主题',
            subtitle: '保存为可分享、可导入的主题包',
            trailing: _rowValue(_exporting ? '导出中' : '导出'),
            onTap: _exporting ? null : _openExportSheet,
          ),
          _embedded(ThemeSection(onAppearanceChanged: _reloadCurrentAppearance)),
        ];
    }
  }

  List<Widget> _buildEditorSegments(ThemeAppearance appearance) {
    final segments = _buildActiveTabSegments(appearance);
    final theme = _expressiveEditorTheme();
    return [
      for (final (index, segment) in segments.indexed) ...[
        if (index > 0) const SizedBox(height: 3),
        _panel(
          key: index == 0
              ? ValueKey('workshop-editor-${_activeTab.name}')
              : null,
          radius:
              _groupRadius(first: false, last: index == segments.length - 1),
          child: Theme(data: theme, child: segment),
        ),
      ],
    ];
  }

  Future<void> _editCourseColor(int index) async {
    final v = _currentVariant;
    final ctrl = TextEditingController(text: v.coursePalette[index]);
    final res = await showAppDialog<String>(
      context: context,
      builder: (ctx) => AppAlertDialog(
        title: Text('修改课程色 ${index + 1}'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: '#RRGGBB'),
        ),
        actions: [
          if (v.coursePalette.length > 5)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(''),
              child: const Text('删除'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final p = ThemeResolver.tryParseHex(ctrl.text);
              if (p != null) {
                Navigator.of(ctx).pop(ThemeResolver.formatHex(p));
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (res == null || !mounted) return;
    _mutate(() {
      if (res.isEmpty) {
        v.coursePalette.removeAt(index);
      } else {
        v.coursePalette[index] = res;
      }
    });
  }

  List<Widget> _buildCourseSegments() {
    final v = _currentVariant;
    final appTokens = AppThemeTokens.of(context);
    final tonal = Theme.of(context)
        .colorScheme
        .surfaceContainerHighest
        .withValues(alpha: .55);

    Widget tile({
      required VoidCallback? onTap,
      required Widget swatch,
      required String label,
      String? caption,
    }) {
      return Material(
        color: tonal,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                swatch,
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: appTokens.textPrimary,
                  ),
                ),
                if (caption != null)
                  Text(
                    caption,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: appTokens.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return [
      _settingRow(
        leading: _rowIcon(Icons.auto_awesome_outlined),
        title: '从种子色生成',
        subtitle: '按主题色生成 6 种课程色，配白色课程文字',
        trailing: _rowValue('生成'),
        onTap: () {
          final generated = ThemeResolver.generateCoursePalette(
              seedColor: ThemeContrast.parseColor(v.seedColor),
              brightness: _brightness);
          _mutate(() => v.coursePalette = generated);
        },
      ),
      _settingRow(
        leading: _rowIcon(Icons.restart_alt_rounded),
        title: '恢复原版课程色',
        subtitle: '蓝、绿、紫、红、橙五色',
        trailing: _rowValue('恢复'),
        onTap: () => _mutate(() =>
            v.coursePalette = ThemeResolver.originalCoursePalette(_brightness)),
      ),
      Padding(
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const gap = 8.0;
            final width = (constraints.maxWidth - 3 * gap) / 4;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < v.coursePalette.length; i++)
                  SizedBox(
                    width: width,
                    child: tile(
                      onTap: () => _editCourseColor(i),
                      swatch: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: ThemeContrast.parseColor(v.coursePalette[i]),
                          borderRadius: BorderRadius.circular(13),
                        ),
                      ),
                      label: '课程 ${i + 1}',
                      caption: v.coursePalette[i],
                    ),
                  ),
                if (v.coursePalette.length < 12)
                  SizedBox(
                    width: width,
                    child: tile(
                      onTap: () =>
                          _mutate(() => v.coursePalette.add('#26A69A')),
                      swatch: SizedBox(
                        width: 40,
                        height: 40,
                        child: Icon(Icons.add_rounded,
                            color: appTokens.textPrimary),
                      ),
                      label: '新增',
                      caption: '${v.coursePalette.length}/12',
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ];
  }

  Future<void> _pickWallpaper({required bool landscape}) async {
    final draft = _state;
    final v = _currentVariant;
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

  List<Widget> _buildWallpaperSegments() {
    final v = _currentVariant;
    final slotData = v.wallpapers[_wallpaperSlot];
    const slots = {
      'global': '全局',
      'home': '首页',
      'schedule': '课表',
      'me': '我的',
    };
    return [
      _choiceGrid<String>(
        title: '壁纸位置',
        values: slots.keys.toList(),
        selected: _wallpaperSlot,
        label: (slot) => slots[slot]!,
        keyOf: (slot) => ValueKey('workshop-wallpaper-slot-$slot'),
        onSelected: (slot) => setState(() => _wallpaperSlot = slot),
      ),
      _settingRow(
        key: const ValueKey('workshop-wallpaper-portrait'),
        leading: _rowIcon(Icons.image_outlined),
        title: '竖屏图',
        subtitle: slotData == null
            ? '未设置，选择后用于${slots[_wallpaperSlot]}页面'
            : '已设置，可调整焦点、模糊与遮罩',
        trailing: _rowValue(slotData == null ? '选择' : '更换'),
        onTap: () => _pickWallpaper(landscape: false),
      ),
      if (slotData != null) ...[
        _settingRow(
          leading: _rowIcon(Icons.stay_current_landscape),
          title: '横屏图',
          subtitle: slotData['landscape'] == null ? '可选，平板和横屏时使用' : '已设置',
          trailing: _rowValue(slotData['landscape'] == null ? '添加' : '更换'),
          onTap: () => _pickWallpaper(landscape: true),
        ),
        _settingRow(
          leading: _rowIcon(Icons.delete_outline_rounded),
          title: '清空此位置',
          subtitle: '恢复使用全局壁纸或默认背景',
          onTap: () => _mutate(() => v.wallpapers[_wallpaperSlot] = null),
        ),
      ],
      if (_brightness == Brightness.dark)
        _settingRow(
          key: const ValueKey('workshop-copy-light-wallpapers'),
          leading: _rowIcon(Icons.copy_outlined),
          title: '复制浅色壁纸设置',
          subtitle: '深色模式沿用浅色的全部壁纸位置',
          onTap: () => _mutate(() {
            _state.dark.wallpapers = {
              for (final entry in _state.light.wallpapers.entries)
                entry.key: entry.value == null
                    ? null
                    : Map<String, dynamic>.from(entry.value!),
            };
          }),
        ),
      if (slotData != null)
        _embedded(
          ThemeImageAdjustmentsEditor(
            settings: slotData,
            onChanged: (updated) =>
                _mutate(() => v.wallpapers[_wallpaperSlot] = updated),
          ),
        ),
    ];
  }

  List<Widget> _buildMaterialSegments() {
    final v = _currentVariant;
    const shapes = {'compact': '紧凑', 'standard': '标准', 'rounded': '圆润'};
    return [
      _choiceGrid<String>(
        title: '全局圆角',
        values: shapes.keys.toList(),
        selected: _state.shape,
        label: (shape) => shapes[shape]!,
        onSelected: (shape) => _mutate(() => _state.shape = shape),
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sliderRow(
            icon: Icons.opacity_rounded,
            title: '卡片不透明度',
            subtitle: '调节卡片底面的不透明程度',
            value: '${(v.componentOpacity * 100).round()}%',
            slider: Slider(
              value: v.componentOpacity.clamp(0.0, 1.0),
              min: 0.0,
              max: 1.0,
              divisions: 100,
              onChanged: (val) => _mutate(
                () => v.componentOpacity = (val * 100).round() / 100,
              ),
            ),
          ),
          _rowDivider(),
          _settingRow(
            leading: _rowIcon(Icons.blur_on_rounded),
            title: '卡片毛玻璃',
            subtitle: '模糊卡片背后的壁纸',
            trailing: _rowSwitch(v.frostedEnabled, (on) => _setFrosted(on)),
            onTap: () => _setFrosted(!v.frostedEnabled),
          ),
          if (v.frostedEnabled) ...[
            _rowDivider(),
            _sliderRow(
              icon: Icons.blur_linear_rounded,
              title: '毛玻璃强度',
              value: '${(v.frostedStrength * 100).round()}%',
              slider: Slider(
                value: v.frostedStrength.clamp(0.0, 1.0),
                min: 0.0,
                max: 1.0,
                divisions: 20,
                onChanged: (val) => _mutate(
                  () => v.frostedStrength = (val * 100).round() / 100,
                ),
              ),
            ),
          ],
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _settingRow(
            leading: _rowIcon(Icons.border_style_rounded),
            title: '描边与阴影',
            subtitle: '内容卡片的描边宽度和阴影强弱',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: ThemeCardStyleEditor(
              cardStyle: v.cardStyle,
              onChanged: (next) => _mutate(() => v.cardStyle = next),
            ),
          ),
        ],
      ),
      _settingRow(
        leading: _rowIcon(Icons.restart_alt_rounded),
        title: '恢复默认材质',
        subtitle: '重置当前明暗的不透明度、毛玻璃与描边阴影',
        onTap: () => _mutate(() {
          v.componentOpacity = 1.0;
          v.frostedEnabled = false;
          v.frostedStrength = 0.0;
          v.cardStyle = null;
        }),
      ),
    ];
  }

  void _setFrosted(bool on) {
    final v = _currentVariant;
    _mutate(() {
      v.frostedEnabled = on;
      if (on && v.frostedStrength == 0) v.frostedStrength = 0.5;
    });
  }

  static const _headerSlots = {'home': '首页', 'campus': '校园', 'me': '我的'};

  Widget _headerSlotGrid(String title) => _choiceGrid<String>(
        title: title,
        values: _headerSlots.keys.toList(),
        selected: _headerSlot,
        label: (slot) => _headerSlots[slot]!,
        keyOf: (slot) => ValueKey('workshop-header-slot-$slot'),
        onSelected: (slot) => setState(() => _headerSlot = slot),
      );

  List<Widget> _buildLayoutSegments() {
    return [
      _headerSlotGrid('页头位置'),
      _embedded(
        ThemeHeaderLayoutEditor(
          slotLabel: _headerSlots[_headerSlot]!,
          rawLayout: _state.layout[_headerSlot],
          decorated: hasHeaderDecoration(_currentVariant.decorations[_headerSlot]),
          onChanged: (next) => _mutate(() {
            if (next == null) {
              _state.layout.remove(_headerSlot);
            } else {
              _state.layout[_headerSlot] = next;
            }
          }),
        ),
      ),
      if (_state.layout.isNotEmpty)
        _settingRow(
          leading: _rowIcon(Icons.restart_alt_rounded),
          title: '重置全部页头布局',
          subtitle: '首页、校园和我的页头恢复默认模板',
          onTap: () => _mutate(() => _state.layout.clear()),
        ),
    ];
  }

  Future<String?> _pickDecorationAsset(ThemeAssetKind kind) async {
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

  List<Widget> _buildDecorationSegments() {
    final v = _currentVariant;
    return [
      _headerSlotGrid('装饰位置'),
      _embedded(
        ThemeHeaderDecorationEditor(
          slot: _headerSlot,
          slotLabel: _headerSlots[_headerSlot]!,
          layoutSpec: ThemeHeaderLayoutSpec.fromMap(_state.layout[_headerSlot]),
          decoration: v.decorations[_headerSlot],
          assetResolver: _resolveLocalImage,
          onPickHeaderBackground: () =>
              _pickDecorationAsset(ThemeAssetKind.header),
          onPickSticker: () => _pickDecorationAsset(ThemeAssetKind.sticker),
          onChanged: (next) => _mutate(() => v.decorations[_headerSlot] = next),
        ),
      ),
    ];
  }

  Future<void> _pickNavIcon(String slot, String iconState) async {
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

  List<Widget> _buildIconSegments() {
    const styles = {
      null: '沿用设置',
      'normal': '标准底栏',
      'floating': '悬浮底栏',
      'liquid_glass': '液态玻璃',
    };
    const tints = {'template': '单色剪影', 'original': '保留原色'};
    final scheme = Theme.of(context).colorScheme;
    final compact = FilledButton.styleFrom(
      backgroundColor: scheme.secondaryContainer,
      foregroundColor: scheme.onSecondaryContainer,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      minimumSize: const Size(0, 34),
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
    );
    return [
      _choiceGrid<String?>(
        title: '本机底栏样式（不随主题导出）',
        values: styles.keys.toList(),
        selected: _state.bottomNavStyle,
        label: (style) => styles[style]!,
        columns: 2,
        onSelected: (style) => _mutate(() => _state.bottomNavStyle = style),
      ),
      _choiceGrid<String>(
        title: '图标着色',
        values: tints.keys.toList(),
        selected: _state.iconTint,
        label: (tint) => tints[tint]!,
        onSelected: (tint) => _mutate(() => _state.iconTint = tint),
      ),
      _settingRow(
        leading: _rowIcon(Icons.apps_rounded),
        title: '导航图标',
        subtitle: '选图后自动居中裁成 192×192 正方形',
      ),
      for (final (slot, name, icon) in const [
        ('home', '首页', Icons.home_outlined),
        ('market', '集市', Icons.storefront_outlined),
        ('schedule', '课表', Icons.calendar_month_outlined),
        ('campus', '校园', Icons.school_outlined),
        ('me', '我', Icons.person_outline_rounded),
      ])
        _settingRow(
          leading: _rowIcon(icon),
          title: name,
          subtitle: _state.navIcons[slot] == null ? '默认图标' : '已自定义',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.tonal(
                style: compact,
                onPressed: () => _pickNavIcon(slot, 'normal'),
                child: const Text('常态'),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                style: compact,
                onPressed: () => _pickNavIcon(slot, 'selected'),
                child: const Text('选中'),
              ),
              if (_state.navIcons[slot] != null)
                IconButton(
                  tooltip: '恢复默认图标',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () => _mutate(() => _state.navIcons[slot] = null),
                ),
            ],
          ),
        ),
    ];
  }

  Future<void> _pickFontFile({required bool bold}) async {
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

  static const _fontLicenses = [
    ('OFL-1.1', 'SIL OFL-1.1', '开源字体常用许可'),
    ('Apache-2.0', 'Apache-2.0', null),
    ('CC0-1.0', 'CC0-1.0', '放弃全部权利'),
    ('author-owned', '作者本人拥有版权', 'author-owned'),
  ];

  List<Widget> _buildFontSegments() {
    final fontMap = _state.font;
    final resolvedFamily = ThemeFontRegistry.resolvedFamilyFor(
      _state.buildAppearance().group(ThemeGroup.font),
    );
    final appTokens = AppThemeTokens.of(context);
    final license = fontMap?['license'] as String? ?? 'OFL-1.1';
    final licenseLabel = _fontLicenses
        .firstWhere((item) => item.$1 == license,
            orElse: () => _fontLicenses.first)
        .$2;
    return [
      _settingRow(
        leading: _rowIcon(Icons.font_download_outlined),
        title: '常规体',
        subtitle: fontMap == null
            ? '选择 .ttf / .otf 字体文件'
            : '${fontMap['name'] ?? '自定义字体'}',
        trailing: _rowValue(fontMap == null ? '选择' : '更换'),
        onTap: () => _pickFontFile(bold: false),
      ),
      if (fontMap != null) ...[
        _settingRow(
          leading: _rowIcon(Icons.format_bold_rounded),
          title: '粗体',
          subtitle: fontMap['bold'] == null ? '可选，未设置时由常规体加粗' : '已设置',
          trailing: _rowValue(fontMap['bold'] == null ? '添加' : '更换'),
          onTap: () => _pickFontFile(bold: true),
        ),
        _settingRow(
          leading: _rowIcon(Icons.verified_outlined),
          title: '字体许可',
          trailing: _rowValue(licenseLabel),
          onTap: () async {
            final picked = await _pickOption<String>(
              current: license,
              options: _fontLicenses,
              keyPrefix: 'workshop-font-license',
            );
            if (picked != null && mounted && _state.font != null) {
              _mutate(() => _state.font = {..._state.font!, 'license': picked});
            }
          },
        ),
        _settingRow(
          leading: _rowIcon(Icons.delete_outline_rounded),
          title: '移除自定义字体',
          subtitle: '恢复系统默认字体',
          onTap: () => _mutate(() => _state.font = null),
        ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '标题样例：沈阳理工大学校园生活',
              style: TextStyle(
                fontFamily: resolvedFamily,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: appTokens.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '正文样例：春风拂过浑河南岸，今天上午八点在主教 302 教室上高等数学。',
              style: TextStyle(
                fontFamily: resolvedFamily,
                fontSize: 14,
                color: appTokens.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '数字与英文：2026-10-18 · Room B204 · GPA 3.92',
              style: TextStyle(
                fontFamily: resolvedFamily,
                fontSize: 13.5,
                color: appTokens.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '等宽对照（保持不变）：0x147C72 · SHA-256',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: appTokens.textSecondary,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  Future<void> _pickCustomLauncher() async {
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

  List<Widget> _buildLauncherIconSegments() {
    final custom = _state.customLauncherIconPath;
    final appTokens = AppThemeTokens.of(context);
    final names = {
      null: '不指定',
      for (final spec in LauncherIconService.builtinIcons) spec.id: spec.name,
    };

    Widget preview(Widget clip, String label) => Column(
          children: [
            clip,
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11.5, color: appTokens.textSecondary),
            ),
          ],
        );

    return [
      _settingRow(
        leading: _rowIcon(Icons.info_outline_rounded),
        title: '随主题包分享的图标',
        subtitle: '本机桌面图标可在「主题包」分类中单独设置',
      ),
      _choiceGrid<String?>(
        title: '内置备选桌面图标',
        values: names.keys.toList(),
        selected: _state.builtinLauncherIcon,
        label: (id) => names[id]!,
        columns: 2,
        onSelected: (id) => _mutate(() => _state.builtinLauncherIcon = id),
      ),
      _settingRow(
        leading: _rowIcon(Icons.add_photo_alternate_outlined),
        title: '自定义图标',
        subtitle: '432–1024px 正方形不透明 PNG/WebP',
        trailing: _rowValue(custom == null ? '选择' : '更换'),
        onTap: _pickCustomLauncher,
      ),
      if (custom != null) ...[
        Padding(
          padding: const EdgeInsets.all(14),
          child: Wrap(
            spacing: 20,
            runSpacing: 12,
            children: [
              preview(
                ClipOval(
                  child: Image.file(File(custom),
                      width: 64, height: 64, fit: BoxFit.cover),
                ),
                '圆形遮罩',
              ),
              preview(
                ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: Image.file(File(custom),
                      width: 64, height: 64, fit: BoxFit.cover),
                ),
                '圆角方形遮罩',
              ),
            ],
          ),
        ),
        _settingRow(
          leading: _rowIcon(Icons.delete_outline_rounded),
          title: '移除自定义图标',
          onTap: () => _mutate(() => _state.customLauncherIconPath = null),
        ),
      ],
    ];
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
