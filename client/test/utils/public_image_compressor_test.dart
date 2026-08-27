import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/utils/public_image_compressor.dart';

void main() {
  test('公开 JPEG 压缩会限制最长边并使用 JPEG 输出', () {
    final source = image.fill(
      image.Image(width: 3000, height: 1200),
      color: image.ColorRgb8(40, 96, 180),
    );
    final compressed = PublicImageCompressor.compressJpegBytes(
      Uint8List.fromList(image.encodeJpg(source, quality: 95)),
    );
    final decoded = image.decodeJpg(compressed);

    expect(decoded, isNotNull);
    expect(decoded!.width, 2048);
    expect(decoded.height, 819);
  });

  test('压缩器异常时保留原始文件供上传回退', () async {
    final root = await Directory.systemTemp.createTemp('public-image-');
    final source = File('${root.path}/source.jpg');
    await source.writeAsBytes(_jpegHeader(width: 3000, height: 1200));
    addTearDown(() => root.delete(recursive: true));

    final compressor = PublicImageCompressor(
      compress: (_) => throw StateError('编码器不可用'),
    );
    final prepared = await compressor.prepare(XFile(source.path));

    expect(prepared.file.path, source.path);
    expect(prepared.isTemporary, isFalse);
  });
}

Uint8List _jpegHeader({required int width, required int height}) {
  return Uint8List.fromList(<int>[
    0xFF,
    0xD8,
    0xFF,
    0xC0,
    0x00,
    0x11,
    0x08,
    height >> 8,
    height & 0xFF,
    width >> 8,
    width & 0xFF,
    0x03,
    0x01,
    0x11,
    0x00,
    0x02,
    0x11,
    0x01,
    0x03,
    0x11,
    0x01,
  ]);
}
