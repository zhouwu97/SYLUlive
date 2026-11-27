import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shenliyuan/features/theme_pack/theme_contrast.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/themed_wallpaper_layer.dart';
import 'package:shenliyuan/theme/app_palette.dart';
import 'package:shenliyuan/theme/app_theme_style.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

Map<String, dynamic> themeFixture(
        {String id = '00000000-0000-4000-8000-000000000001',
        int version = 1}) =>
    {
      'formatVersion': 1,
      'minAppVersion': '1.0.0',
      'id': id,
      'version': version,
      'name': '测试主题',
      'author': '测试作者',
      'license': 'personal-use',
      'preview': {'light': 'preview/cover.png', 'dark': 'preview/cover.png'},
      for (final mode in Brightness.values)
        (mode == Brightness.light ? 'light' : 'dark'): {
          'seedColor': '#147C72',
          'tokens': AppPalette.defaults(mode).toJson(),
          'coursePalette': [
            '#448AFF',
            '#00C853',
            '#9C27B0',
            '#FF5252',
            '#FF9800'
          ],
        },
    };

Uint8List themeImage(int width, int height) => Uint8List.fromList(
    image.encodePng(image.Image(width: width, height: height)));
Uint8List? _cover;
Uint8List themeArchive(Map<String, dynamic> manifest,
    {Map<String, Uint8List> files = const {}, bool includePreview = true}) {
  final archive = Archive();
  final text = utf8.encode(jsonEncode(manifest));
  archive.addFile(ArchiveFile('manifest.json', text.length, text));
  if (includePreview) {
    final cover = _cover ??= themeImage(1080, 2340);
    archive.addFile(ArchiveFile('preview/cover.png', cover.length, cover));
  }
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List alterThemeZip(Uint8List original, String entry,
    {bool crc = false, int? size}) {
  final bytes = Uint8List.fromList(original);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i + 46 < bytes.length; i++) {
    final signature = data.getUint32(i, Endian.little);
    final local = signature == 0x04034b50;
    final central = signature == 0x02014b50;
    if (!local && !central) continue;
    final nameOffset = local ? 30 : 46;
    final nameLength = data.getUint16(i + (local ? 26 : 28), Endian.little);
    if (i + nameOffset + nameLength > bytes.length) continue;
    if (String.fromCharCodes(
            bytes.sublist(i + nameOffset, i + nameOffset + nameLength)) !=
        entry) {
      continue;
    }
    if (crc) {
      data.setUint32(
          i + (local ? 14 : 16),
          data.getUint32(i + (local ? 14 : 16), Endian.little) ^ 0x01010101,
          Endian.little);
    }
    if (size != null) {
      data.setUint32(i + (local ? 22 : 24), size, Endian.little);
    }
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TypeMatcher<ThemePackError> failsWith(String code) =>
      isA<ThemePackError>().having((error) => error.code, 'code', code);

  test('主题卡片接受 0–100% 不透明度，拒绝越界值', () {
    for (final opacity in [-.01, 0.0, .42, .75, 1.0, 1.01]) {
      final json = themeFixture();
      for (final mode in ['light', 'dark']) {
        json[mode]['componentOpacity'] = opacity;
      }
      if (opacity < 0 || opacity > 1) {
        expect(() => ThemeManifest.parse(json, appVersion: '9.0.0'),
            throwsA(failsWith('theme_field_invalid')));
      } else {
        final manifest = ThemeManifest.parse(json, appVersion: '9.0.0');
        for (final mode in ['light', 'dark']) {
          expect(manifest.data[mode]['componentOpacity'], opacity);
        }
      }
    }
  });

  test('本机来源不可伪装官方；忽略无关条目并完整解码合法图片', () async {
    final manifest = themeFixture()..['source'] = 'official';
    final pack = await ThemePackCodec.decode(
        themeArchive(manifest, files: {
          '../unused.txt': Uint8List.fromList([1, 2])
        }),
        appVersion: '9.0.0');
    expect(pack.manifest.data.containsKey('source'), isFalse);
    expect(pack.contents.keys, ['preview/cover.png']);
  });

  final invalid = <(String, Uint8List Function())>[
    ('theme_zip_invalid', () => Uint8List.fromList([1, 2, 3])),
    ('theme_too_large', () => Uint8List(ThemePackCodec.maxPackageBytes + 1)),
    (
      'theme_manifest_invalid',
      () => Uint8List.fromList(ZipEncoder().encode(Archive()))
    ),
    (
      'theme_format_unsupported',
      () => themeArchive(themeFixture()..['formatVersion'] = 2)
    ),
    (
      'theme_app_too_old',
      () => themeArchive(themeFixture()..['minAppVersion'] = '99.0.0')
    ),
    (
      'theme_field_invalid',
      () => themeArchive(themeFixture()..['id'] = '../escape')
    ),
    (
      'theme_asset_missing',
      () => themeArchive(themeFixture(), includePreview: false)
    ),
    (
      'theme_image_invalid',
      () => themeArchive(
              themeFixture()
                ..['preview'] = {
                  'light': 'preview/bad.png',
                  'dark': 'preview/bad.png'
                },
              files: {
                'preview/bad.png': Uint8List.fromList([1, 2, 3])
              })
    ),
    (
      'theme_font_invalid',
      () => themeArchive(
          themeFixture()
            ..['font'] = {
              'name': '坏字体',
              'regular': 'fonts/bad.ttf',
              'license': 'OFL-1.1'
            },
          files: {'fonts/bad.ttf': Uint8List(12)})
    ),
  ];
  for (var i = 0; i < invalid.length; i++) {
    final (code, build) = invalid[i];
    test('边界错误 $i：$code', () async {
      await expectLater(ThemePackCodec.decode(build(), appVersion: '9.0.0'),
          throwsA(failsWith(code)));
    });
  }
  for (final entry in ['manifest.json', 'preview/cover.png']) {
    test('内容可解压但 CRC 错误：$entry', () async {
      await expectLater(
          ThemePackCodec.decode(
              alterThemeZip(themeArchive(themeFixture()), entry, crc: true),
              appVersion: '9.0.0'),
          throwsA(failsWith('theme_zip_invalid')));
    });
  }
  test('解压总量超 96MB 在读取资源前停止；伪报更小体积也被实际输出限制拦截', () async {
    final original = themeArchive(themeFixture());
    await expectLater(
        ThemePackCodec.decode(
            alterThemeZip(original, 'preview/cover.png',
                size: ThemePackCodec.maxExpandedBytes + 1),
            appVersion: '9.0.0'),
        throwsA(failsWith('theme_too_large')));
    await expectLater(
        ThemePackCodec.decode(
            alterThemeZip(original, 'preview/cover.png', size: 1),
            appVersion: '9.0.0'),
        throwsA(failsWith('theme_zip_invalid')));
  });
  test('图片先校验尺寸，错误预览尺寸不能进入应用', () async {
    final manifest = themeFixture()
      ..['preview'] = {
        'light': 'preview/small.png',
        'dark': 'preview/small.png'
      };
    await expectLater(
        ThemePackCodec.decode(
            themeArchive(manifest,
                files: {'preview/small.png': themeImage(4, 4)}),
            appVersion: '9.0.0'),
        throwsA(failsWith('theme_image_invalid')));
  });
  test('布局装饰与调色保留，删除的密度、锐化和重复圆角字段不进入规范数据', () async {
    final json = themeFixture()
      ..['layout'] = {
        'home': {'preset': 'immersive', 'density': 'compact'}
      };
    json['light']
        ['cardStyle'] = {'borderWidth': 2, 'shadow': 'soft', 'radius': 30};
    json['light']['decorations'] = {
      'home': {
        'background': {
          'image': 'decorations/header.png',
          'adjustments': {
            'brightness': -20,
            'contrast': 120,
            'saturation': 80,
            'sharpen': 1
          }
        },
        'stickers': [
          {
            'image': 'decorations/sticker.png',
            'x': 0,
            'y': 1,
            'width': .4,
            'rotation': -180
          }
        ],
      }
    };
    final pack = await ThemePackCodec.decode(
        themeArchive(json, files: {
          'decorations/header.png': themeImage(240, 120),
          'decorations/sticker.png': themeImage(48, 48),
        }),
        appVersion: '9.0.0');
    expect(pack.manifest.data['layout']['home']['preset'], 'immersive');
    expect(
        pack.manifest.data['layout']['home'].containsKey('density'), isFalse);
    expect(pack.manifest.data['light']['cardStyle'].containsKey('radius'),
        isFalse);
    expect(
        pack.manifest.data['light']['decorations']['home']['background']
            ['adjustments'],
        {'brightness': -20.0, 'contrast': 120.0, 'saturation': 80.0});
    expect(pack.contents.keys,
        containsAll(['decorations/header.png', 'decorations/sticker.png']));
    expect(
        pack.manifest.groups,
        containsAll([
          ThemeGroup.material,
          ThemeGroup.layout,
          ThemeGroup.decoration,
        ]));
  });

  test('V2 字段：氛围背景、识别色协调、卡片填充、区块记号、状态插画与标题字体', () async {
    final json = themeFixture();
    json['light']
      ..['identityHarmony'] = .6
      ..['cardStyle'] = {'fill': 'tint'}
      ..['backdrop'] = {
        'gradient': {
          'colors': ['#EAF2FF', '#FFF6EE'],
          'angle': 160
        },
        'glow': [
          {'color': '#BFD6FF', 'x': .9, 'y': .1}
        ],
        'pattern': {'tile': 'decorations/tile.png', 'opacity': .2}
      }
      ..['sectionMark'] = {'style': 'icon', 'image': 'decorations/mark.png'}
      ..['illustrations'] = {'empty': 'decorations/empty.png'}
      ..['ornaments'] = {
        'postCard': {'image': 'decorations/ear.png', 'width': 56, 'dy': -20},
        'fab': {'image': 'decorations/ear.png', 'width': 64, 'dy': -40},
      }
      ..['serviceIcons'] = {'edu': 'icons/edu.png', 'search': 'icons/edu.png'};
    final pack = await ThemePackCodec.decode(
        themeArchive(json, files: {
          'decorations/tile.png': themeImage(64, 64),
          'decorations/mark.png': themeImage(48, 48),
          'decorations/empty.png': themeImage(400, 400),
          'decorations/ear.png': themeImage(224, 112),
          'icons/edu.png': themeImage(256, 256),
        }),
        appVersion: '9.0.0');
    final light = pack.manifest.data['light'] as Map;
    expect(light['identityHarmony'], .6);
    expect(light['cardStyle'], {'fill': 'tint'});
    expect(light['backdrop']['glow'][0]['radius'], .5);
    expect(light['sectionMark'], {'style': 'icon', 'image': 'decorations/mark.png'});
    expect(light['ornaments']['fab']['dy'], -40);
    expect(light['ornaments']['postCard'], {
      'image': 'decorations/ear.png',
      'corner': 'topRight',
      'width': 56,
      'dx': 0,
      'dy': -20,
      'opacity': 1,
    });
    expect(light['serviceIcons'], {'edu': 'icons/edu.png', 'search': 'icons/edu.png'});
    expect(pack.manifest.groups,
        containsAll([ThemeGroup.wallpapers, ThemeGroup.decoration]));
    expect(
        pack.manifest.assets
            .where((a) => a.kind == ThemeAssetKind.illustration)
            .map((a) => a.path),
        ['decorations/empty.png']);

    for (final bad in <Map<String, dynamic>>[
      {'backdrop': <String, dynamic>{}},
      {
        'backdrop': {
          'gradient': {
            'colors': ['#FFFFFF']
          }
        }
      },
      {'sectionMark': {'style': 'icon'}},
      {'identityHarmony': 1.5},
      {'cardStyle': {'fill': 'neon'}},
      {
        'ornaments': {
          'postCard': {'image': 'decorations/ear.png', 'width': 400}
        }
      },
    ]) {
      final broken = themeFixture();
      final light = broken['light'] as Map;
      for (final entry in bad.entries) {
        light[entry.key] = entry.value as Object;
      }
      expect(
          () => ThemeManifest.parse(broken, appVersion: '9.0.0'),
          throwsA(isA<ThemePackError>()
              .having((e) => e.code, 'code', 'theme_field_invalid')),
          reason: '$bad');
    }

    final titleOnly = themeFixture()
      ..['font'] = {
        'title': {
          'name': '标题',
          'regular': 'fonts/title.ttf',
          'license': 'OFL-1.1'
        }
      };
    final parsed = ThemeManifest.parse(titleOnly, appVersion: '9.0.0');
    expect(parsed.data['font'].containsKey('regular'), isFalse);
    expect(parsed.assets.where((a) => a.kind == ThemeAssetKind.font).single.path,
        'fonts/title.ttf');
  });

  test('识别色协调与标题字号规则：强度 0 原样返回，协调后色相靠近主色、色调不变', () {
    const orange = Color(0xFFFF7A45);
    const style0 = AppThemeStyle();
    expect(style0.identity(orange), orange);
    const style = AppThemeStyle(
        identityHarmony: .7, identityAnchor: Color(0xFF3C6090));
    final source = Hct.fromInt(orange.toARGB32());
    final result = Hct.fromInt(style.identity(orange).toARGB32());
    final anchor = Hct.fromInt(const Color(0xFF3C6090).toARGB32());
    double distance(double a, double b) => ((a - b + 540) % 360 - 180).abs();
    expect(distance(result.hue, anchor.hue),
        lessThan(distance(source.hue, anchor.hue)));
    expect(result.tone, closeTo(source.tone, 1.5));
    const titled = AppThemeStyle(titleFontFamily: 'theme_title_x');
    expect(titled.title(const TextStyle(fontSize: 14)).fontFamily, isNull);
    expect(titled.title(const TextStyle(fontSize: 18)).fontFamily,
        'theme_title_x');
  });

  test('图片颜色矩阵：中性参数为单位矩阵，非中性严格按亮度→对比度→饱和度顺序计算', () {
    final identity = ThemedWallpaperLayer.buildColorMatrix();
    expect(identity, <double>[
      1, 0, 0, 0, 0,
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ]);
    expect(
      ThemedWallpaperLayer.isNeutralAdjustments(
        const {'brightness': 0, 'contrast': 100, 'saturation': 100},
      ),
      isTrue,
    );

    final matrix = ThemedWallpaperLayer.buildColorMatrix(
      brightness: 20,
      contrast: 150,
      saturation: 50,
    );
    (double, double, double) applyMatrix(double r, double g, double b) => (
          (matrix[0] * r + matrix[1] * g + matrix[2] * b + matrix[4])
              .clamp(0.0, 255.0),
          (matrix[5] * r + matrix[6] * g + matrix[7] * b + matrix[9])
              .clamp(0.0, 255.0),
          (matrix[10] * r + matrix[11] * g + matrix[12] * b + matrix[14])
              .clamp(0.0, 255.0),
        );

    // 按契约 2.9 逐步归一化计算：亮度(+0.2) → 对比度(*1.5 around 0.5) → 饱和度(*0.5)
    double stepContrast(double u) => (u + 0.2 - 0.5) * 1.5 + 0.5;
    final r2 = stepContrast(100 / 255.0);
    final g2 = stepContrast(140 / 255.0);
    final b2 = stepContrast(180 / 255.0);
    final luma = 0.2126 * r2 + 0.7152 * g2 + 0.0722 * b2;
    final expectedR = (luma + (r2 - luma) * 0.5) * 255.0;
    final expectedG = (luma + (g2 - luma) * 0.5) * 255.0;
    final expectedB = (luma + (b2 - luma) * 0.5) * 255.0;

    final (actualR, actualG, actualB) = applyMatrix(100, 140, 180);
    expect(actualR, closeTo(expectedR, 0.01));
    expect(actualG, closeTo(expectedG, 0.01));
    expect(actualB, closeTo(expectedB, 0.01));
  });
  test('中央目录计数错误、损坏 JSON 和未配对导航图标不能导入', () async {
    final raw = themeArchive(themeFixture());
    final duplicateZip = Uint8List.fromList(raw);
    final eocd = duplicateZip.length - 22;
    ByteData.sublistView(duplicateZip).setUint16(eocd + 10, 99, Endian.little);
    await expectLater(ThemePackCodec.decode(duplicateZip, appVersion: '9.0.0'),
        throwsA(failsWith('theme_zip_invalid')));
    final malformed = Archive()
      ..addFile(ArchiveFile('manifest.json', 1, [123]));
    await expectLater(
        ThemePackCodec.decode(
            Uint8List.fromList(ZipEncoder().encode(malformed)),
            appVersion: '9.0.0'),
        throwsA(failsWith('theme_manifest_invalid')));
    final json = themeFixture()
      ..['bottomNav'] = {
        'icons': {
          'home': {'normal': 'icons/a.png'}
        }
      };
    await expectLater(
        ThemePackCodec.decode(themeArchive(json), appVersion: '9.0.0'),
        throwsA(failsWith('theme_field_invalid')));
  });
  test('对比度规则：精确计算、透明合成和所有规则的低对比组合', () {
    expect(ThemeContrast.ratio(Colors.black, Colors.white), 21);
    expect(
        ThemeContrast.ratio(const Color(0xff777777), Colors.white)
            .toStringAsFixed(2),
        '4.48');
    final manifest = themeFixture();
    for (final mode in ['light', 'dark']) {
      final tokens = manifest[mode]['tokens'] as Map<String, String>;
      for (final key in tokens.keys.toList()) {
        tokens[key] = '#777777';
      }
      manifest[mode]['coursePalette'] = List.filled(5, '#777777');
    }
    final issues =
        ThemeContrast.check(ThemeManifest.parse(manifest, appVersion: '9.0.0'));
    // 9 条规则 × 明暗两套；课程块文字不参与硬性对比度检查。
    expect(issues.length, 18);
    expect(issues.any((issue) => issue.foreground == 'courseCardText'), isFalse);
    expect(issues.every((issue) => issue.ratio == 1), isTrue);
  });
  final badFields = <(String, void Function(Map<String, dynamic>))>[
    ('tokens', (m) => m['light']['tokens']['primary'] = '#80FFFFFF'),
    (
      'wallpaper path',
      (m) => m['light']['wallpapers'] = {
            'global': {'portrait': '../outside.png'}
          }
    ),
    (
      'template',
      (m) => m['layout'] = {
            'home': {'preset': 'script'}
          }
    ),
    (
      'image width',
      (m) => m['layout'] = {
            'home': {'imageWidth': .1}
          }
    ),
    (
      'adjustments',
      (m) => m['light']['wallpapers'] = {
            'global': {
              'portrait': 'wallpaper/a.png',
              'adjustments': {'contrast': 201}
            }
          }
    ),
    (
      'stickers',
      (m) => m['light']['decorations'] = {
            'home': {'stickers': List.filled(6, {})}
          }
    ),
    (
      'rotation',
      (m) => m['light']['decorations'] = {
            'home': {
              'stickers': [
                {
                  'image': 'decorations/a.png',
                  'x': .5,
                  'y': .5,
                  'width': .2,
                  'rotation': 181
                }
              ]
            }
          }
    ),
  ];
  for (final (name, change) in badFields) {
    test('字段边界：$name', () {
      final manifest = themeFixture();
      change(manifest);
      expect(() => ThemeManifest.parse(manifest, appVersion: '9.0.0'),
          throwsA(failsWith('theme_field_invalid')));
    });
  }
}
