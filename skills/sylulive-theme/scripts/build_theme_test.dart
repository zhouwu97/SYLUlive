import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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
    final problems = await _skillRuleProblems(source, data);
    if (problems.isNotEmpty) {
      fail('不符合 SKILL.md 硬性规则：\n${problems.join('\n')}');
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

/// SKILL.md「硬性规则」：一次收集全部问题，方便一轮改完。
Future<List<String>> _skillRuleProblems(
  String source,
  Map<String, dynamic> data,
) async {
  final problems = <String>{};
  Future<(int, int)?> sizeOf(String path) async {
    final file = File('$source/$path');
    if (!await file.exists()) {
      problems.add('缺少文件 $path');
      return null;
    }
    final bytes = await file.readAsBytes();
    final info = img.findDecoderForData(bytes)?.startDecode(bytes);
    if (info == null) {
      problems.add('无法读取图片尺寸 $path');
      return null;
    }
    return (info.width, info.height);
  }

  if ((data['bottomNav'] as Map?)?.containsKey('style') ?? false) {
    problems.add('删除 bottomNav.style：底栏样式是用户的设备偏好');
  }
  final layout = (data['layout'] as Map?) ?? const {};
  for (final mode in Brightness.values) {
    final variant = data[mode.name] as Map<String, dynamic>;
    final decorations = (variant['decorations'] as Map?) ?? const {};
    for (final slot in const ['home', 'campus', 'me']) {
      final deco = decorations[slot] as Map?;
      final background = deco?['background'] as Map?;
      final stickers = (deco?['stickers'] as List?) ?? const [];
      if (background == null && stickers.isEmpty) continue;
      final header = layout[slot] as Map?;
      final height = (header?['imageHeight'] as num?) ?? 0;
      if (header?['preset'] != 'immersive' || height < 140 || height > 160) {
        problems.add('layout.$slot 需显式写 preset: immersive，imageHeight 140–160');
      }
      if (background == null) continue;
      final size = await sizeOf(background['image'] as String);
      if (size == null) continue;
      final (w, h) = size;
      final ratio = w / h;
      if (math.max(w, h) < 1800 || ratio < 2.3 || ratio > 2.9) {
        problems.add('${mode.name} $slot 页头图 $w×$h：需长边 ≥1800、宽高比 2.3–2.9');
      }
    }
    final wallpapers = (variant['wallpapers'] as Map?) ?? const {};
    for (final entry in wallpapers.entries) {
      if (entry.value case {'portrait': final String path}) {
        final size = await sizeOf(path);
        if (size == null) continue;
        final (w, h) = size;
        if (math.min(w, h) < 1080 || math.max(w, h) < 2340) {
          problems.add('${mode.name} 壁纸 ${entry.key} 为 $w×$h，不足 1080×2340');
        }
      }
    }
  }
  return problems.toList();
}
