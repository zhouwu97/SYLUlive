import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 主题素材处理：contact 总览、slice 宫格切图、fit 按焦点裁切缩放。
/// 在 client/ 下运行，参数见 references/asset-production.md。
void main() {
  test('主题素材工具', () async {
    const tool = String.fromEnvironment('TOOL');
    const input = String.fromEnvironment('IN');
    const output = String.fromEnvironment('OUT');
    if (input.isEmpty || output.isEmpty) fail('请传入 IN 和 OUT');
    switch (tool) {
      case 'contact':
        await _contact(input, output);
      case 'slice':
        await _slice(input, output, const String.fromEnvironment('GRID'));
      case 'fit':
        await _fit(
          input,
          output,
          const String.fromEnvironment('SIZE'),
          const String.fromEnvironment('FOCUS', defaultValue: '0.5,0.5'),
        );
      default:
        fail('TOOL 只能是 contact、slice 或 fit');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

const _imageSuffixes = ['.png', '.jpg', '.jpeg', '.webp'];

Future<img.Image> _read(String path) async {
  final decoded = img.decodeImage(await File(path).readAsBytes());
  if (decoded == null) throw StateError('无法解码 $path');
  return decoded;
}

Future<void> _write(img.Image image, String path) async {
  await File(path).parent.create(recursive: true);
  final lower = path.toLowerCase();
  final bytes = lower.endsWith('.jpg') || lower.endsWith('.jpeg')
      ? img.encodeJpg(image, quality: 90)
      : img.encodePng(image);
  await File(path).writeAsBytes(bytes);
  print('$path ${image.width}×${image.height}');
}

/// 每格 240×240，标注从 1 开始的编号；超过 48 张时输出 OUT-2.png 等多张。
Future<void> _contact(String dir, String out) async {
  final files = Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => _imageSuffixes.any(f.path.toLowerCase().endsWith))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) fail('$dir 下没有图片');
  const cell = 240, cols = 8, perSheet = 48;
  final index = StringBuffer();
  for (var start = 0; start < files.length; start += perSheet) {
    final page = files.skip(start).take(perSheet).toList();
    final rows = (page.length / cols).ceil();
    final sheet = img.Image(width: cols * cell, height: rows * cell);
    img.fill(sheet, color: img.ColorRgb8(245, 245, 245));
    for (var i = 0; i < page.length; i++) {
      final number = start + i + 1;
      index.writeln('$number\t${page[i].path}');
      final x = (i % cols) * cell, y = (i ~/ cols) * cell;
      try {
        final src = await _read(page[i].path);
        final scale = math.min((cell - 8) / src.width, (cell - 28) / src.height);
        final thumb = img.copyResize(src,
            width: math.max(1, (src.width * scale).round()),
            height: math.max(1, (src.height * scale).round()),
            interpolation: img.Interpolation.average);
        img.compositeImage(sheet, thumb,
            dstX: x + (cell - thumb.width) ~/ 2, dstY: y + 24);
      } on Object catch (e) {
        index.writeln('  解码失败：$e');
      }
      img.drawString(sheet, '$number', font: img.arial24, x: x + 4, y: y,
          color: img.ColorRgb8(200, 30, 30));
    }
    final sheetIndex = start ~/ perSheet;
    final path =
        sheetIndex == 0 ? out : out.replaceFirst(RegExp(r'\.png$'), '-${sheetIndex + 1}.png');
    await _write(sheet, path);
  }
  final indexPath = out.replaceFirst(RegExp(r'\.png$'), '.txt');
  await File(indexPath).writeAsString(index.toString());
  print('编号对照：$indexPath');
}

/// 按 GRID（列x行）切开，裁掉每格四周的透明边，输出 01.png、02.png……
Future<void> _slice(String path, String outDir, String grid) async {
  final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(grid);
  if (match == null) fail('GRID 格式为 列x行，例如 3x2');
  final cols = int.parse(match[1]!), rows = int.parse(match[2]!);
  final sheet = (await _read(path)).convert(numChannels: 4);
  final cellW = sheet.width ~/ cols, cellH = sheet.height ~/ rows;
  var n = 0;
  for (var r = 0; r < rows; r++) {
    for (var c = 0; c < cols; c++) {
      n++;
      final cell = img.copyCrop(sheet,
          x: c * cellW, y: r * cellH, width: cellW, height: cellH);
      final box = img.findTrim(cell, mode: img.TrimMode.transparent);
      final trimmed = box[2] > 0 && box[3] > 0
          ? img.copyCrop(cell, x: box[0], y: box[1], width: box[2], height: box[3])
          : cell;
      await _write(trimmed, '$outDir/${n.toString().padLeft(2, '0')}.png');
    }
  }
}

/// 按焦点 cover 裁切到目标比例，再缩放到 SIZE；不放大低清图。
Future<void> _fit(String path, String out, String size, String focus) async {
  final sizeMatch = RegExp(r'^(\d+)x(\d+)$').firstMatch(size);
  if (sizeMatch == null) fail('SIZE 格式为 宽x高，例如 2000x760');
  final w = int.parse(sizeMatch[1]!), h = int.parse(sizeMatch[2]!);
  final parts = focus.split(',').map(double.parse).toList();
  final src = await _read(path);
  final targetRatio = w / h;
  var cropW = src.width, cropH = src.height;
  if (src.width / src.height > targetRatio) {
    cropW = (src.height * targetRatio).round();
  } else {
    cropH = (src.width / targetRatio).round();
  }
  if (cropW < w || cropH < h) {
    fail('原图裁切后只有 $cropW×$cropH，小于目标 $w×$h，不放大低清图，请重新生成');
  }
  final x = ((src.width - cropW) * parts[0]).round().clamp(0, src.width - cropW);
  final y = ((src.height - cropH) * parts[1]).round().clamp(0, src.height - cropH);
  final cropped = img.copyCrop(src, x: x, y: y, width: cropW, height: cropH);
  await _write(
    img.copyResize(cropped,
        width: w, height: h, interpolation: img.Interpolation.average),
    out,
  );
}
