import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/theme_pack/theme_contrast.dart';
import 'package:shenliyuan/features/theme_pack/theme_manifest.dart';
import 'package:shenliyuan/features/theme_pack/theme_pack_codec.dart';
import 'package:shenliyuan/features/theme_pack/theme_resolver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('制作主题并通过本机导入校验', () async {
    const source = String.fromEnvironment('THEME_SOURCE');
    const output = String.fromEnvironment('THEME_OUTPUT');
    if (source.isEmpty || output.isEmpty) {
      fail('请传入 THEME_SOURCE 制作目录和 THEME_OUTPUT 输出文件路径');
    }
    final data =
        jsonDecode(await File('$source/manifest.json').readAsString())
            as Map<String, dynamic>;
    if (data.containsKey('font')) {
      fail('此制作流程保留 App 原字体，请从制作清单移除 font（含 title）后再打包');
    }
    for (final mode in Brightness.values) {
      final variant = data[mode.name] as Map<String, dynamic>;
      final seed = ThemeContrast.parseColor(variant['seedColor'] as String);
      final tokens = ThemeResolver.deriveTokens(
        seedColor: seed,
        brightness: mode,
        schemeVariant: ThemeResolver.parseSchemeVariant(
          variant['schemeVariant'],
        ),
        overrides: Map<String, String>.from(variant['tokens'] ?? {}),
      );
      variant['tokens'] = tokens;
      variant['coursePalette'] ??= ThemeResolver.generateCoursePalette(
        seedColor: seed,
        brightness: mode,
        background: ThemeContrast.parseColor(tokens['background']!),
        courseCardText: ThemeContrast.parseColor(tokens['courseCardText']!),
      );
    }
    final pubspec = await File('pubspec.yaml').readAsString();
    final version = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)',
      multiLine: true,
    ).firstMatch(pubspec)![1]!;
    final manifest = ThemeManifest.parse(data, appVersion: version);
    final files = <String, Uint8List>{};
    for (final path in manifest.assets.map((asset) => asset.path).toSet()) {
      files[path] = await File('$source/$path').readAsBytes();
    }
    final bytes = await ThemePackCodec.encode(manifest, files);
    final decoded = await ThemePackCodec.decode(bytes, appVersion: version);
    final issues = ThemeContrast.check(decoded.manifest);
    expect(
      issues,
      isEmpty,
      reason: issues
          .map(
            (issue) =>
                '${issue.brightness.name} ${issue.foreground}/${issue.background}: '
                '${issue.ratio.toStringAsFixed(2)} < ${issue.minimum}',
          )
          .join('\n'),
    );
    final packed = decoded.manifest;
    final nav = packed.data['bottomNav'] as Map?;
    final navIcons = nav?['icons'] as Map? ?? const {};
    for (final entry in navIcons.entries) {
      if (entry.value case final Map pair) {
        if (listEquals(
          decoded.contents[pair['normal']],
          decoded.contents[pair['selected']],
        )) {
          fail('底栏 ${entry.key} 的常态和选中态使用了相同的图片');
        }
      }
    }
    final destination = await File(output).create(exclusive: true);
    await destination.writeAsBytes(bytes, flush: true);
    print(
      '包内分组：${packed.groups.map((g) => g.label).join('、')}；'
      '底栏双态图标：${navIcons.values.whereType<Map>().length}/5',
    );
    for (final mode in Brightness.values) {
      final variant = packed.variant(mode);
      final slots = [
        for (final field in [
          'decorations',
          'ornaments',
          'illustrations',
          'serviceIcons',
        ])
          if (variant[field] case final Map values)
            '$field=[${values.entries.where((e) => e.value != null).map((e) => e.key).join(', ')}]',
      ];
      print('${mode.name} 包内组件资源：${slots.join(' ')}');
    }
  });
}
