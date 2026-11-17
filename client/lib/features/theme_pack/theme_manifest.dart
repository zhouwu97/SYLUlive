import 'dart:ui' show Brightness;

import '../../theme/app_palette.dart';

enum ThemeGroup {
  colors('配色'),
  shape('圆角'),
  wallpapers('壁纸'),
  material('卡片材质'),
  navigation('导航栏'),
  font('字体'),
  widgets('桌面小部件'),
  launcherIcon('桌面图标'),
  layout('页头布局'),
  decoration('页头装饰');

  const ThemeGroup(this.label);
  final String label;

  static const applicable = {
    colors,
    shape,
    wallpapers,
    material,
    navigation,
    font,
    widgets,
    launcherIcon,
  };
}

class ThemePackError implements Exception {
  const ThemePackError(this.code, [this.field = '', this.detail = '']);
  final String code;
  final String field;
  final String detail;

  String get message => switch (code) {
        'theme_zip_invalid' => '这不是有效的主题文件',
        'theme_too_large' => '主题文件过大',
        'theme_manifest_invalid' => '主题描述信息损坏',
        'theme_format_unsupported' => '这个主题需要更新版本的 App',
        'theme_app_too_old' => '请升级到 $detail 后再使用',
        'theme_asset_missing' => '主题缺少资源：$field',
        'theme_image_invalid' => '主题图片不符合要求：$field',
        'theme_font_invalid' => '主题字体无法使用：$field',
        _ => detail.isNotEmpty ? detail : '主题设置有误：$field',
      };

  @override
  String toString() => '$code ($field): $message';
}

enum ThemeAssetKind {
  preview,
  wallpaper,
  icon,
  launcher,
  font,
  header,
  sticker
}

class ThemeAsset {
  const ThemeAsset(this.path, this.kind);
  final String path;
  final ThemeAssetKind kind;
}

/// 本机文件仅在 parse 边界校验；安装后的规范数据直接读取。
class ThemeManifest {
  const ThemeManifest.fromStored(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  int get version => data['version'] as int;
  String get name => data['name'] as String;
  String get author => data['author'] as String;
  String get description => data['description'] as String? ?? '';
  Map<String, dynamic> variant(Brightness brightness) =>
      data[brightness == Brightness.dark ? 'dark' : 'light']
          as Map<String, dynamic>;

  Set<ThemeGroup> get groups => {
        ThemeGroup.colors,
        ThemeGroup.widgets,
        if (data.containsKey('shape')) ThemeGroup.shape,
        if (['light', 'dark']
            .any((key) => (data[key] as Map).containsKey('wallpapers')))
          ThemeGroup.wallpapers,
        if ([
          'light',
          'dark'
        ].any((key) => (data[key] as Map).keys.any((field) =>
            ['componentOpacity', 'frostedGlass'].contains(field))))
          ThemeGroup.material,
        if (data.containsKey('bottomNav')) ThemeGroup.navigation,
        if (data.containsKey('font')) ThemeGroup.font,
        if (data.containsKey('launcherIcon')) ThemeGroup.launcherIcon,
        if (data.containsKey('layout')) ThemeGroup.layout,
        if (['light', 'dark']
            .any((key) => (data[key] as Map).containsKey('decorations')))
          ThemeGroup.decoration,
      };

  Iterable<ThemeAsset> get assets sync* {
    final preview = data['preview'] as Map;
    for (final value in preview.values) {
      yield ThemeAsset(value as String, ThemeAssetKind.preview);
    }
    for (final mode in ['light', 'dark']) {
      final v = data[mode] as Map;
      for (final wallpaper in ((v['wallpapers'] as Map?) ?? {}).values) {
        if (wallpaper == null) continue;
        yield ThemeAsset(
            wallpaper['portrait'] as String, ThemeAssetKind.wallpaper);
        if (wallpaper['landscape'] != null) {
          yield ThemeAsset(
              wallpaper['landscape'] as String, ThemeAssetKind.wallpaper);
        }
      }
      for (final decoration in ((v['decorations'] as Map?) ?? {}).values) {
        if (decoration == null) continue;
        if (decoration['background'] != null) {
          yield ThemeAsset(decoration['background']['image'] as String,
              ThemeAssetKind.header);
        }
        for (final sticker in decoration['stickers'] as List) {
          yield ThemeAsset(sticker['image'] as String, ThemeAssetKind.sticker);
        }
      }
    }
    for (final icon in ((data['bottomNav']?['icons'] as Map?) ?? {}).values) {
      if (icon == null) continue;
      for (final image in (icon as Map).values) {
        yield ThemeAsset(image as String, ThemeAssetKind.icon);
      }
    }
    final font = data['font'] as Map?;
    if (font != null) {
      yield ThemeAsset(font['regular'] as String, ThemeAssetKind.font);
      if (font['bold'] != null) {
        yield ThemeAsset(font['bold'] as String, ThemeAssetKind.font);
      }
    }
    final launcher = data['launcherIcon'] as Map?;
    if (launcher?['custom'] != null) {
      yield ThemeAsset(launcher!['custom'] as String, ThemeAssetKind.launcher);
    }
  }

  factory ThemeManifest.parse(Object? input, {required String appVersion}) {
    final parser = _ManifestParser();
    final source = parser.object(input, 'manifest');
    if (source['formatVersion'] is! int) parser.invalid('formatVersion');
    if (source['formatVersion'] != 1) {
      throw const ThemePackError('theme_format_unsupported', 'formatVersion');
    }
    final minimum =
        parser.text(source['minAppVersion'], 'minAppVersion', 1, 30);
    final semver = RegExp(r'^\d+\.\d+\.\d+$');
    if (!semver.hasMatch(minimum)) parser.invalid('minAppVersion');
    final required = minimum.split('.').map(BigInt.parse).toList();
    final installed = appVersion.split('.').map(BigInt.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (installed[i] < required[i]) {
        throw ThemePackError('theme_app_too_old', 'minAppVersion', minimum);
      }
      if (installed[i] > required[i]) break;
    }
    final id = parser.text(source['id'], 'id', 36, 36);
    if (!RegExp(
            r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$')
        .hasMatch(id)) {
      parser.invalid('id');
    }
    final version = source['version'];
    if (version is! int || version < 1) parser.invalid('version');
    final preview = parser.object(source['preview'], 'preview');
    final result = <String, dynamic>{
      'formatVersion': 1,
      'minAppVersion': minimum,
      'id': id.toLowerCase(),
      'version': version,
      'name': parser.text(source['name'], 'name', 1, 20),
      'author': parser.text(source['author'], 'author', 1, 20),
      'description': source['description'] == null
          ? ''
          : parser.text(source['description'], 'description', 0, 200,
              multiline: true),
      'license': parser.choice(source['license'], 'license',
          const ['CC0-1.0', 'CC-BY-4.0', 'CC-BY-NC-4.0', 'personal-use']),
      'preview': {
        for (final mode in ['light', 'dark'])
          mode: parser.path(preview[mode], 'preview.$mode', 'preview')
      },
      for (final mode in ['light', 'dark'])
        mode: parser.variant(source[mode], mode),
    };
    if (source['tags'] != null) {
      final tags = parser.list(source['tags'], 'tags', 0, 5);
      result['tags'] = [
        for (final tag in tags)
          parser.choice(tag, 'tags', const [
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
            '科技'
          ])
      ];
    }
    if (source['shape'] != null) {
      result['shape'] = parser.choice(
          source['shape'], 'shape', const ['compact', 'standard', 'rounded']);
    }
    if (source['bottomNav'] != null) {
      final nav = parser.object(source['bottomNav'], 'bottomNav');
      final icons = nav['icons'] == null
          ? <String, dynamic>{}
          : parser.object(nav['icons'], 'bottomNav.icons');
      result['bottomNav'] = {
        if (nav['style'] != null)
          'style': parser.choice(nav['style'], 'bottomNav.style',
              const ['normal', 'floating', 'liquid_glass']),
        'iconTint': parser.choice(nav['iconTint'] ?? 'template',
            'bottomNav.iconTint', const ['template', 'original']),
        'icons': {
          for (final slot in const [
            'home',
            'market',
            'schedule',
            'campus',
            'me'
          ])
            slot: icons[slot] == null
                ? null
                : parser.icon(icons[slot], 'bottomNav.icons.$slot')
        },
      };
    }
    if (source['font'] != null) {
      final font = parser.object(source['font'], 'font');
      result['font'] = {
        'name': parser.text(font['name'], 'font.name', 1, 30),
        'regular': parser.path(font['regular'], 'font.regular', 'fonts'),
        if (font['bold'] != null)
          'bold': parser.path(font['bold'], 'font.bold', 'fonts'),
        'license': parser.choice(font['license'], 'font.license',
            const ['OFL-1.1', 'Apache-2.0', 'CC0-1.0', 'author-owned']),
      };
    }
    if (source['launcherIcon'] != null) {
      final launcher = parser.object(source['launcherIcon'], 'launcherIcon');
      if (launcher['builtin'] == null && launcher['custom'] == null) {
        parser.invalid('launcherIcon');
      }
      result['launcherIcon'] = {
        if (launcher['builtin'] != null)
          'builtin': parser.choice(launcher['builtin'], 'launcherIcon.builtin',
              const ['default', 'night', 'sea', 'sakura', 'paper', 'campus']),
        if (launcher['custom'] != null)
          'custom': parser.path(
              launcher['custom'], 'launcherIcon.custom', 'icons',
              transparent: true),
      };
    }
    if (source['layout'] != null) {
      final layout = parser.object(source['layout'], 'layout');
      result['layout'] = {
        for (final slot in const ['home', 'campus', 'me'])
          if (layout[slot] != null)
            slot: parser.header(layout[slot], 'layout.$slot')
      };
    }
    return ThemeManifest.fromStored(result);
  }
}

class _ManifestParser {
  Never invalid(String field) =>
      throw ThemePackError('theme_field_invalid', field);
  Map<String, dynamic> object(Object? value, String field) =>
      value is Map<String, dynamic> ? value : invalid(field);
  List<dynamic> list(Object? value, String field, int min, int max) =>
      value is List && value.length >= min && value.length <= max
          ? value
          : invalid(field);
  String text(Object? value, String field, int min, int max,
      {bool multiline = false}) {
    if (value is! String ||
        value.runes.length < min ||
        value.runes.length > max ||
        (!multiline && RegExp(r'[\r\n]').hasMatch(value))) {
      invalid(field);
    }
    return value;
  }

  String choice(Object? value, String field, List<String> values) =>
      value is String && values.contains(value) ? value : invalid(field);
  double number(Object? value, String field, double min, double max) =>
      value is num && value.isFinite && value >= min && value <= max
          ? value.toDouble()
          : invalid(field);
  bool boolean(Object? value, String field) =>
      value is bool ? value : invalid(field);
  String color(Object? value, String field, {bool alpha = false}) {
    if (value is! String ||
        !RegExp(alpha
                ? r'^#(?:[a-fA-F0-9]{6}|[a-fA-F0-9]{8})$'
                : r'^#[a-fA-F0-9]{6}$')
            .hasMatch(value)) {
      invalid(field);
    }
    return value.toUpperCase();
  }

  String path(Object? value, String field, String folder,
      {bool transparent = false}) {
    final extensions = folder == 'fonts'
        ? 'ttf|otf'
        : transparent
            ? 'png|webp'
            : 'png|jpg|webp';
    if (value is! String ||
        !RegExp('^$folder/[a-z0-9_-]{1,40}\\.($extensions)\$')
            .hasMatch(value)) {
      invalid(field);
    }
    return value;
  }

  Map<String, dynamic> icon(Object? value, String field) {
    final item = object(value, field);
    return {
      for (final state in ['normal', 'selected'])
        state: path(item[state], '$field.$state', 'icons', transparent: true)
    };
  }

  Map<String, dynamic> adjustments(Object? value, String field) {
    final v = object(value, field);
    return {
      'brightness':
          number(v['brightness'] ?? 0, '$field.brightness', -100, 100),
      'contrast': number(v['contrast'] ?? 100, '$field.contrast', 0, 200),
      'saturation': number(v['saturation'] ?? 100, '$field.saturation', 0, 200),
    };
  }

  Map<String, dynamic> imageSettings(
          Map<String, dynamic> source, String field) =>
      {
        'fit': choice(
            source['fit'] ?? 'cover', '$field.fit', const ['cover', 'contain']),
        'focalX': number(source['focalX'] ?? .5, '$field.focalX', 0, 1),
        'focalY': number(source['focalY'] ?? .5, '$field.focalY', 0, 1),
        'blur': number(source['blur'] ?? 0, '$field.blur', 0, 20),
        'scrim': number(source['scrim'] ?? 0, '$field.scrim', 0, .6),
        if (source['adjustments'] != null)
          'adjustments':
              adjustments(source['adjustments'], '$field.adjustments'),
      };
  Map<String, dynamic> wallpaper(Object? value, String field) {
    final v = object(value, field);
    return {
      'portrait': path(v['portrait'], '$field.portrait', 'wallpaper'),
      if (v['landscape'] != null)
        'landscape': path(v['landscape'], '$field.landscape', 'wallpaper'),
      ...imageSettings(v, field),
    };
  }

  Map<String, dynamic> header(Object? value, String field) {
    final v = object(value, field);
    return {
      'preset': choice(v['preset'] ?? 'standard', '$field.preset',
          const ['standard', 'compact', 'immersive']),
      'alignment': choice(v['alignment'] ?? 'start', '$field.alignment',
          const ['start', 'center', 'end']),
      'imageHeight':
          number(v['imageHeight'] ?? 160, '$field.imageHeight', 96, 280),
      'imageWidth': number(v['imageWidth'] ?? 1, '$field.imageWidth', .45, 1),
    };
  }

  Map<String, dynamic> decoration(Object? value, String field) {
    final v = object(value, field);
    final background = v['background'] == null
        ? null
        : object(v['background'], '$field.background');
    final stickers = list(v['stickers'] ?? [], '$field.stickers', 0, 5);
    return {
      if (background != null)
        'background': {
          'image': path(
              background['image'], '$field.background.image', 'decorations'),
          ...imageSettings(background, '$field.background'),
        },
      'stickers': [
        for (var i = 0; i < stickers.length; i++)
          sticker(stickers[i], '$field.stickers[$i]')
      ],
    };
  }

  Map<String, dynamic> sticker(Object? value, String field) {
    final v = object(value, field);
    return {
      'image':
          path(v['image'], '$field.image', 'decorations', transparent: true),
      'x': number(v['x'], '$field.x', 0, 1),
      'y': number(v['y'], '$field.y', 0, 1),
      'width': number(v['width'], '$field.width', .08, .4),
      'rotation': number(v['rotation'] ?? 0, '$field.rotation', -180, 180),
    };
  }

  Map<String, dynamic> variant(Object? value, String field) {
    final v = object(value, field);
    final tokens = object(v['tokens'], '$field.tokens');
    const translucent = {
      'cardBorder',
      'divider',
      'outline',
      'navBackground',
      'appBarBackground',
      'timetableGrid',
      'timetableToday'
    };
    final course = list(v['coursePalette'], '$field.coursePalette', 5, 12);
    final walls = v['wallpapers'] == null
        ? null
        : object(v['wallpapers'], '$field.wallpapers');
    final frost = v['frostedGlass'] == null
        ? null
        : object(v['frostedGlass'], '$field.frostedGlass');
    final style = v['cardStyle'] == null
        ? null
        : object(v['cardStyle'], '$field.cardStyle');
    final decorations = v['decorations'] == null
        ? null
        : object(v['decorations'], '$field.decorations');
    return {
      'seedColor': color(v['seedColor'], '$field.seedColor'),
      'schemeVariant': choice(
          v['schemeVariant'] ?? 'tonalSpot', '$field.schemeVariant', const [
        'tonalSpot',
        'neutral',
        'vibrant',
        'expressive',
        'fidelity',
        'content'
      ]),
      'tokens': {
        for (final key in AppPalette.defaults(Brightness.light).toJson().keys)
          key: color(tokens[key], '$field.tokens.$key',
              alpha: translucent.contains(key))
      },
      'coursePalette': [
        for (var i = 0; i < course.length; i++)
          color(course[i], '$field.coursePalette[$i]')
      ],
      if (walls != null)
        'wallpapers': {
          for (final slot in ['global', 'home', 'schedule', 'me'])
            slot: walls[slot] == null
                ? null
                : wallpaper(walls[slot], '$field.wallpapers.$slot')
        },
      if (v['componentOpacity'] != null)
        'componentOpacity':
            number(v['componentOpacity'], '$field.componentOpacity', .75, 1),
      if (frost != null)
        'frostedGlass': {
          'enabled': boolean(frost['enabled'], '$field.frostedGlass.enabled'),
          'strength':
              number(frost['strength'], '$field.frostedGlass.strength', 0, 1),
        },
      if (style != null)
        'cardStyle': {
          if (style['borderWidth'] != null)
            'borderWidth': number(
                style['borderWidth'], '$field.cardStyle.borderWidth', 0, 2),
          if (style['shadow'] != null)
            'shadow': choice(style['shadow'], '$field.cardStyle.shadow',
                const ['none', 'soft', 'medium']),
        },
      if (decorations != null)
        'decorations': {
          for (final slot in ['home', 'campus', 'me'])
            slot: decorations[slot] == null
                ? null
                : decoration(decorations[slot], '$field.decorations.$slot')
        },
    };
  }
}
