import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;

import '../../theme/app_palette.dart';
import 'theme_appearance.dart';
import 'theme_contrast.dart';
import 'theme_manifest.dart';
import 'theme_pack_codec.dart';

typedef ThemePreviewCapture = Future<(Uint8List, Uint8List)> Function(
  ThemeManifest manifest,
  Map<String, Uint8List> contents,
);

class RawWallpaperInput {
  const RawWallpaperInput({
    required this.bytes,
    required this.extension,
    required this.fit,
    required this.blur,
  });

  final Uint8List bytes;
  final String extension;
  final String fit;
  final double blur;
}

/// 将当前生效的混搭外观（含多主题分组混搭与手动壁纸/材质/导航设置）打包为标准 .sltheme。
abstract final class ThemeAppearanceExporter {
  static Map<String, dynamic> headerLayout(
    Map? layout, Map<String, dynamic> light, Map<String, dynamic> dark,
  ) {
    final result = Map<String, dynamic>.from(layout ?? const {});
    for (final slot in const ['home', 'campus', 'me']) {
      final lightArt = hasHeaderDecoration((light['decorations'] as Map?)?[slot] as Map?);
      final darkArt = hasHeaderDecoration((dark['decorations'] as Map?)?[slot] as Map?);
      if (!lightArt && !darkArt) continue;
      final header = result[slot] as Map?;
      // 单侧有装饰时，另一模式仍可使用作者选择的紧凑排版。
      if (header?['preset'] == 'compact' && lightArt != darkArt) continue;
      result[slot] = <String, dynamic>{
        if (header != null) ...Map<String, dynamic>.from(header),
        'preset': 'immersive',
        'imageHeight': header?['imageHeight'] ?? 150,
      };
    }
    return result;
  }

  static String sanitizeFileName(String raw, {String fallback = 'theme'}) {
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '_')
        .trim();
    return cleaned.isEmpty ? fallback : cleaned;
  }

  static Future<Uint8List> export({
    required ThemeAppearance appearance,
    ThemePreviewCapture? capturePreview,
    required String name,
    required String author,
    required String appVersion,
    required bool shouldExportManualMaterial,
    required double manualComponentOpacity,
    required bool manualFrostedGlass,
    required double manualFrostedStrength,
    RawWallpaperInput? manualPortraitWallpaper,
    RawWallpaperInput? manualLandscapeWallpaper,
  }) async {
    final safeName = _clampRunes(
      name.replaceAll(RegExp(r'[\r\n]'), ' ').trim(),
      fallback: '我的混搭外观',
      max: 20,
    );
    final safeAuthor = _clampRunes(
      author.replaceAll(RegExp(r'[\r\n]'), ' ').trim(),
      fallback: '本机导出',
      max: 20,
    );
    final normalizedVersion = RegExp(r'^\d+\.\d+\.\d+$').hasMatch(appVersion)
        ? appVersion
        : '1.0.0';

    final filesToRead = <String, String>{};
    final contents = <String, Uint8List>{};
    var assetCounter = 0;

    String registerLocalAsset(String localPath, String folder) {
      final existing = filesToRead[localPath];
      if (existing != null) return existing;
      final ext = _normalizeExtension(path.extension(localPath), folder: folder);
      final archivePath = '$folder/asset_${++assetCounter}.$ext';
      filesToRead[localPath] = archivePath;
      return archivePath;
    }

    final colorsGroup = appearance.group(ThemeGroup.colors);
    final shapeGroup = appearance.group(ThemeGroup.shape);
    final wallpapersGroup = appearance.group(ThemeGroup.wallpapers);
    final materialGroup = appearance.group(ThemeGroup.material);
    final navigationGroup = appearance.group(ThemeGroup.navigation);
    final fontGroup = appearance.group(ThemeGroup.font);
    final launcherGroup = appearance.group(ThemeGroup.launcherIcon);
    final layoutGroup = appearance.group(ThemeGroup.layout);
    final decorationGroup = appearance.group(ThemeGroup.decoration);

    Map<String, dynamic> buildVariant(Brightness brightness) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      final effectivePalette = appearance.buildTheme(brightness).extension<AppPalette>()!;
      final storedColors = colorsGroup?[mode] as Map<String, dynamic>?;
      final tokens = effectivePalette.toJson();
      final seedColor = storedColors?['seedColor'] as String? ?? '#147C72';
      final schemeVariant =
          storedColors?['schemeVariant'] as String? ?? 'tonalSpot';
      final coursePalette = [
        for (final color in effectivePalette.coursePalette)
          '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
      ];

      Map<String, dynamic>? exportedWallpapers;
      if (wallpapersGroup != null && wallpapersGroup['legacy'] == null) {
        final modeWalls = wallpapersGroup[mode] as Map?;
        if (modeWalls != null) {
          final slots = <String, dynamic>{};
          var hasAny = false;
          for (final slot in const [
            'global',
            'home',
            'schedule',
            'me',
            'secondary',
          ]) {
            final item = modeWalls[slot] as Map?;
            if (item == null) {
              slots[slot] = null;
              continue;
            }
            hasAny = true;
            slots[slot] = {
              'portrait':
                  registerLocalAsset(item['portrait'] as String, 'wallpaper'),
              if (item['landscape'] != null)
                'landscape': registerLocalAsset(
                    item['landscape'] as String, 'wallpaper'),
              'fit': item['fit'] ?? 'cover',
              'focalX': (item['focalX'] as num? ?? .5).toDouble(),
              'focalY': (item['focalY'] as num? ?? .5).toDouble(),
              'blur': (item['blur'] as num? ?? 0).toDouble().clamp(0.0, 20.0),
              'scrim': (item['scrim'] as num? ?? 0).toDouble().clamp(0.0, 0.6),
              if (item['adjustments'] != null)
                'adjustments':
                    Map<String, dynamic>.from(item['adjustments'] as Map),
            };
          }
          if (hasAny) exportedWallpapers = slots;
        }
      } else if (manualPortraitWallpaper != null ||
          manualLandscapeWallpaper != null) {
        final primary = manualPortraitWallpaper ?? manualLandscapeWallpaper!;
        const portraitEntry = 'wallpaper/manual_portrait';
        final portraitArchive =
            '$portraitEntry.${_normalizeExtension(primary.extension, folder: 'wallpaper')}';
        contents[portraitArchive] = primary.bytes;
        String? landscapeArchive;
        if (manualLandscapeWallpaper != null &&
            manualPortraitWallpaper != null) {
          landscapeArchive =
              'wallpaper/manual_landscape.${_normalizeExtension(manualLandscapeWallpaper.extension, folder: 'wallpaper')}';
          contents[landscapeArchive] = manualLandscapeWallpaper.bytes;
        }
        exportedWallpapers = {
          'global': {
            'portrait': portraitArchive,
            if (landscapeArchive != null) 'landscape': landscapeArchive,
            'fit': primary.fit,
            'focalX': 0.5,
            'focalY': 0.5,
            'blur': primary.blur.clamp(0.0, 20.0),
            'scrim': brightness == Brightness.dark ? 0.35 : 0.25,
          },
          'home': null,
          'schedule': null,
          'me': null,
        };
      }

      double? componentOpacity;
      Map<String, dynamic>? frostedGlass;
      Map<String, dynamic>? cardStyle;
      if (materialGroup != null && materialGroup['legacy'] != true) {
        final modeMat = materialGroup[mode] as Map?;
        if (modeMat != null) {
          componentOpacity = (modeMat['componentOpacity'] as num? ?? 1.0)
              .toDouble()
              .clamp(0.0, 1.0);
          final frost = modeMat['frostedGlass'] as Map?;
          if (frost != null) {
            frostedGlass = {
              'enabled': frost['enabled'] == true,
              'strength':
                  (frost['strength'] as num? ?? 0).toDouble().clamp(0.0, 1.0),
            };
          }
          if (modeMat['cardStyle'] != null) {
            cardStyle = Map<String, dynamic>.from(modeMat['cardStyle'] as Map);
          }
        }
      } else if (shouldExportManualMaterial) {
        componentOpacity = manualComponentOpacity.clamp(0.0, 1.0);
        frostedGlass = {
          'enabled': manualFrostedGlass,
          'strength':
              (manualFrostedGlass ? manualFrostedStrength : 0.0).clamp(0.0, 1.0),
        };
      }

      Map<String, dynamic>? exportedDecorations;
      if (decorationGroup != null) {
        final modeDeco = decorationGroup[mode] as Map?;
        if (modeDeco != null) {
          final slots = <String, dynamic>{};
          var hasAny = false;
          for (final slot in const ['home', 'campus', 'me']) {
            final item = modeDeco[slot] as Map?;
            if (item == null) {
              slots[slot] = null;
              continue;
            }
            hasAny = true;
            final bg = item['background'] as Map?;
            final stickers = (item['stickers'] as List? ?? const []);
            slots[slot] = {
              if (bg != null)
                'background': {
                  ...Map<String, dynamic>.from(bg),
                  'image':
                      registerLocalAsset(bg['image'] as String, 'decorations'),
                },
              'stickers': [
                for (final sticker in stickers)
                  {
                    ...Map<String, dynamic>.from(sticker as Map),
                    'image': registerLocalAsset(
                        sticker['image'] as String, 'decorations'),
                  },
              ],
            };
          }
          if (hasAny) exportedDecorations = slots;
        }
      }

      // V2 附加参数：识别色协调、氛围背景、区块记号与状态插画。
      final modeColors = colorsGroup?[mode] as Map?;
      final harmony = (modeColors?['identityHarmony'] as num?)?.toDouble();
      Map? rawBackdrop;
      if (wallpapersGroup?['legacy'] == null) {
        final modeWallpapers = wallpapersGroup?[mode] as Map?;
        rawBackdrop = modeWallpapers?['backdrop'] as Map?;
      }
      Map<String, dynamic>? exportedBackdrop;
      if (rawBackdrop != null) {
        final pattern = rawBackdrop['pattern'] as Map?;
        exportedBackdrop = {
          ...Map<String, dynamic>.from(rawBackdrop),
          if (pattern != null)
            'pattern': {
              ...Map<String, dynamic>.from(pattern),
              'tile': registerLocalAsset(pattern['tile'] as String, 'decorations'),
            },
        };
      }
      final modeDecoration = decorationGroup?[mode] as Map?;
      final rawMark = modeDecoration?['sectionMark'] as Map?;
      final rawIllustrations = modeDecoration?['illustrations'] as Map?;
      final rawOrnaments = modeDecoration?['ornaments'] as Map?;
      final rawServiceIcons = modeDecoration?['serviceIcons'] as Map?;
      final rawCardArt = modeDecoration?['cardArt'] as Map?;

      return {
        'seedColor': seedColor,
        'schemeVariant': schemeVariant,
        'tokens': tokens,
        'coursePalette': coursePalette,
        if (harmony != null) 'identityHarmony': harmony,
        if (exportedBackdrop != null) 'backdrop': exportedBackdrop,
        if (rawMark != null)
          'sectionMark': {
            'style': rawMark['style'],
            if (rawMark['image'] != null)
              'image': registerLocalAsset(rawMark['image'] as String, 'decorations'),
          },
        if (rawIllustrations != null && rawIllustrations.isNotEmpty)
          'illustrations': {
            for (final entry in rawIllustrations.entries)
              entry.key as String:
                  registerLocalAsset(entry.value as String, 'decorations'),
          },
        if (rawOrnaments != null && rawOrnaments.isNotEmpty)
          'ornaments': {
            for (final entry in rawOrnaments.entries)
              entry.key as String: {
                ...Map<String, dynamic>.from(entry.value as Map),
                'image': registerLocalAsset(
                    (entry.value as Map)['image'] as String, 'decorations'),
              },
          },
        if (rawServiceIcons != null && rawServiceIcons.isNotEmpty)
          'serviceIcons': {
            for (final entry in rawServiceIcons.entries)
              entry.key as String:
                  registerLocalAsset(entry.value as String, 'icons'),
          },
        if (rawCardArt != null)
          'cardArt': {
            ...Map<String, dynamic>.from(rawCardArt),
            'image':
                registerLocalAsset(rawCardArt['image'] as String, 'decorations'),
          },
        if (exportedWallpapers != null) 'wallpapers': exportedWallpapers,
        if (componentOpacity != null) 'componentOpacity': componentOpacity,
        if (frostedGlass != null) 'frostedGlass': frostedGlass,
        if (cardStyle != null && cardStyle.isNotEmpty) 'cardStyle': cardStyle,
        if (exportedDecorations != null) 'decorations': exportedDecorations,
      };
    }

    final lightVariant = buildVariant(Brightness.light);
    final darkVariant = buildVariant(Brightness.dark);

    Map<String, dynamic>? exportedBottomNav;
    final storedIcons = navigationGroup?['icons'] as Map?;
    final exportedIcons = <String, dynamic>{};
    var hasNavIcons = false;
    for (final slot in const ['home', 'market', 'schedule', 'campus', 'me']) {
      final pair = storedIcons?[slot] as Map?;
      if (pair == null || pair['normal'] == null || pair['selected'] == null) {
        exportedIcons[slot] = null;
      } else {
        hasNavIcons = true;
        exportedIcons[slot] = {
          'normal': registerLocalAsset(pair['normal'] as String, 'icons'),
          'selected': registerLocalAsset(pair['selected'] as String, 'icons'),
        };
      }
    }
    if (navigationGroup != null || hasNavIcons) {
      exportedBottomNav = {
        'iconTint': (navigationGroup?['iconTint'] as String?) ?? 'template',
        'icons': exportedIcons,
      };
    }

    Map<String, dynamic>? exportedFont;
    final titleFont = fontGroup?['title'] as Map?;
    if (fontGroup != null &&
        (fontGroup['regular'] != null || titleFont?['regular'] != null)) {
      exportedFont = {
        if (fontGroup['regular'] != null) ...{
          'name': fontGroup['name'] as String,
          'regular':
              registerLocalAsset(fontGroup['regular'] as String, 'fonts'),
          if (fontGroup['bold'] != null)
            'bold': registerLocalAsset(fontGroup['bold'] as String, 'fonts'),
          'license': fontGroup['license'] as String? ?? 'OFL-1.1',
        },
        if (titleFont?['regular'] != null)
          'title': {
            'name': titleFont!['name'] as String,
            'regular':
                registerLocalAsset(titleFont['regular'] as String, 'fonts'),
            'license': titleFont['license'] as String? ?? 'OFL-1.1',
          },
      };
    }

    Map<String, dynamic>? exportedLauncher;
    if (launcherGroup != null &&
        (launcherGroup['builtin'] != null || launcherGroup['custom'] != null)) {
      exportedLauncher = {
        if (launcherGroup['builtin'] != null)
          'builtin': launcherGroup['builtin'] as String,
        if (launcherGroup['custom'] != null)
          'custom':
              registerLocalAsset(launcherGroup['custom'] as String, 'icons'),
      };
    }

    final exportedLayout = headerLayout(
      layoutGroup?['value'] as Map?, lightVariant, darkVariant,
    );

    for (final entry in filesToRead.entries) {
      contents[entry.value] = await File(entry.key).readAsBytes();
    }

    final manifestMap = <String, dynamic>{
      'formatVersion': 1,
      'minAppVersion': normalizedVersion,
      'id': _newUuidV4(),
      'version': 1,
      'name': safeName,
      'author': safeAuthor,
      'description': '从本机当前外观导出的混搭主题包',
      'license': 'personal-use',
      'preview': {
        'light': 'preview/light.jpg',
        'dark': 'preview/dark.jpg',
      },
      'shape': shapeGroup?['value'] as String? ?? 'standard',
      'light': lightVariant,
      'dark': darkVariant,
      if (exportedBottomNav != null) 'bottomNav': exportedBottomNav,
      if (exportedFont != null) 'font': exportedFont,
      if (exportedLauncher != null) 'launcherIcon': exportedLauncher,
      if (exportedLayout.isNotEmpty) 'layout': exportedLayout,
    };

    final manifest =
        ThemeManifest.parse(manifestMap, appVersion: normalizedVersion);
    final finalized = await Isolate.run(() {
      final normalizedContents = Map<String, Uint8List>.from(contents);
      for (final key in normalizedContents.keys.toList()) {
        if (key.startsWith('wallpaper/manual_')) {
          normalizedContents[key] =
              _normalizeWallpaperBytes(normalizedContents[key]!, key);
        }
      }
      return normalizedContents;
    });

    final rendered = await capturePreview?.call(manifest, finalized);
    final (light, dark) = await Isolate.run(() => rendered == null
        ? (_renderPreviewJpeg(lightVariant), _renderPreviewJpeg(darkVariant))
        : (encodePreviewJpeg(img.decodePng(rendered.$1)!),
            encodePreviewJpeg(img.decodePng(rendered.$2)!)));
    finalized['preview/light.jpg'] = light;
    finalized['preview/dark.jpg'] = dark;

    return ThemePackCodec.encode(manifest, finalized);
  }

  static Future<RawWallpaperInput?> readWallpaperSource(
    String? bgPath, {
    required bool fillScreen,
    required double blur,
    required bool Function(String) isBundledAsset,
    required bool Function(String) isLocalFile,
    required String Function(String) resolveBundledAssetPath,
  }) async {
    if (bgPath == null || bgPath.isEmpty) return null;
    try {
      Uint8List bytes;
      String ext;
      if (isBundledAsset(bgPath)) {
        final assetPath = resolveBundledAssetPath(bgPath);
        final data = await rootBundle.load(assetPath);
        bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        ext = path.extension(assetPath);
      } else if (isLocalFile(bgPath)) {
        final localPath = bgPath.startsWith('file://')
            ? File.fromUri(Uri.parse(bgPath)).path
            : bgPath;
        final file = File(localPath);
        if (!await file.exists()) return null;
        bytes = await file.readAsBytes();
        ext = path.extension(localPath);
      } else {
        return null;
      }
      return RawWallpaperInput(
        bytes: bytes,
        extension: ext,
        fit: fillScreen ? 'cover' : 'contain',
        blur: blur,
      );
    } catch (_) {
      return null;
    }
  }

  static String _normalizeExtension(String raw, {required String folder}) {
    final lower = raw.toLowerCase().replaceFirst('.', '');
    if (folder == 'fonts') {
      return lower == 'otf' ? 'otf' : 'ttf';
    }
    if (lower == 'jpeg' || lower == 'jpg') {
      return folder == 'icons' ? 'png' : 'jpg';
    }
    if (lower == 'webp') return 'webp';
    return 'png';
  }

  static Uint8List _normalizeWallpaperBytes(Uint8List bytes, String archiveKey) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    var current = decoded;
    if (current.width > 4096 || current.height > 4096) {
      final scale = 4096 / math.max(current.width, current.height);
      current = img.copyResize(
        current,
        width: math.max(1, (current.width * scale).round()),
        height: math.max(1, (current.height * scale).round()),
      );
    }
    if (archiveKey.endsWith('.jpg')) {
      if (current == decoded &&
          bytes.length >= 3 &&
          bytes[0] == 255 &&
          bytes[1] == 216 &&
          bytes[2] == 255 &&
          bytes.length <= 8 * 1024 * 1024) {
        return bytes;
      }
      return Uint8List.fromList(img.encodeJpg(current, quality: 88));
    }
    if (current == decoded && bytes.length <= 8 * 1024 * 1024) {
      return bytes;
    }
    return Uint8List.fromList(img.encodePng(current));
  }

  static Uint8List encodePreviewJpeg(img.Image image) {
    for (final quality in const [88, 78, 68, 58]) {
      final bytes = img.encodeJpg(image,
          quality: quality, chroma: img.JpegChroma.yuv420);
      if (bytes.length <= ThemePackCodec.maxPreviewBytes) return bytes;
    }
    throw const ThemePackError(
        'theme_image_invalid', 'preview', '预览图压缩后仍超过 2MB');
  }

  static Uint8List _renderPreviewJpeg(Map<String, dynamic> variant) {
    final tokens = variant['tokens'] as Map<String, dynamic>;
    img.ColorRgba8 parse(String key) {
      final c = ThemeContrast.parseColor(tokens[key] as String);
      return img.ColorRgba8(
        (c.r * 255.0).round() & 0xff,
        (c.g * 255.0).round() & 0xff,
        (c.b * 255.0).round() & 0xff,
        (c.a * 255.0).round() & 0xff,
      );
    }

    final canvas = img.Image(width: 1080, height: 2340);
    img.fill(canvas, color: parse('background'));
    img.fillRect(canvas,
        x1: 0, y1: 0, x2: 1080, y2: 180, color: parse('appBarBackground'));
    img.fillRect(canvas,
        x1: 72,
        y1: 252,
        x2: 1008,
        y2: 820,
        color: parse('card'),
        radius: 36);
    img.fillRect(canvas,
        x1: 132,
        y1: 320,
        x2: 520,
        y2: 368,
        color: parse('textPrimary'),
        radius: 12);
    img.fillRect(canvas,
        x1: 132,
        y1: 404,
        x2: 860,
        y2: 440,
        color: parse('textSecondary'),
        radius: 10);
    img.fillRect(canvas,
        x1: 132,
        y1: 520,
        x2: 420,
        y2: 616,
        color: parse('primary'),
        radius: 24);
    final palette = variant['coursePalette'] as List;
    for (var i = 0; i < math.min(5, palette.length); i++) {
      final c = ThemeContrast.parseColor(palette[i] as String);
      final left = 72 + i * 190;
      img.fillRect(
        canvas,
        x1: left,
        y1: 900,
        x2: left + 166,
        y2: 1180,
        color: img.ColorRgba8(
          (c.r * 255.0).round() & 0xff,
          (c.g * 255.0).round() & 0xff,
          (c.b * 255.0).round() & 0xff,
          200,
        ),
        radius: 28,
      );
    }
    img.fillRect(canvas,
        x1: 72,
        y1: 2120,
        x2: 1008,
        y2: 2268,
        color: parse('navBackground'),
        radius: 48);
    return encodePreviewJpeg(canvas);
  }

  static String _clampRunes(String input,
      {required String fallback, required int max}) {
    if (input.isEmpty) return fallback;
    final runes = input.runes.toList();
    if (runes.length <= max) return input;
    return String.fromCharCodes(runes.take(max));
  }

  static String _newUuidV4() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}
