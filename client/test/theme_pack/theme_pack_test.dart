import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:shenliyuan/features/theme_pack/theme_contrast.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/theme/app_palette.dart';

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
    expect(pack.manifest.groups.contains(ThemeGroup.material), isFalse);
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
    expect(issues.length, 28);
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
