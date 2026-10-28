import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:shenliyuan/utils/public_image_compressor.dart';
import 'package:shenliyuan/utils/public_image_upload_policy.dart';

void main() {
  test('JPEG 在体积合适时保留分辨率和长图比例', () {
    final source = image.fill(
      image.Image(width: 3000, height: 1200),
      color: image.ColorRgb8(40, 96, 180),
    );
    final compressed = PublicImageCompressor.compressJpegBytes(
      Uint8List.fromList(image.encodeJpg(source, quality: 95)),
    );
    final decoded = image.decodeJpg(compressed);

    expect(decoded, isNotNull);
    expect(decoded!.width, 3000);
    expect(decoded.height, 1200);
  });

  test('压缩器异常时保留原始文件供上传回退', () async {
    final root = await Directory.systemTemp.createTemp('public-image-');
    final source = File('${root.path}/source.jpg');
    await source.writeAsBytes([
      ..._jpegHeader(width: 3000, height: 1200),
      ...List<int>.filled(6 * 1024 * 1024, 0),
    ]);
    addTearDown(() => root.delete(recursive: true));

    final compressor = PublicImageCompressor(
      compress: (_) => throw StateError('编码器不可用'),
    );
    final prepared = await compressor.prepare(XFile(source.path));

    expect(prepared.file.path, source.path);
    expect(prepared.isTemporary, isFalse);
  });

  test('超过10MB的源图处理后约5MB，保留尺寸并清理副本', () async {
    final root = await Directory.systemTemp.createTemp('staged-image-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/large.jpg');
    final original = image.encodeJpg(image.Image(width: 600, height: 600));
    await source.writeAsBytes(original);
    final handle = await source.open(mode: FileMode.append);
    await handle.truncate(12 * 1024 * 1024);
    await handle.close();
    final prepared = await PublicImageCompressor().prepare(XFile(source.path));
    expect(prepared.isTemporary, isTrue);
    expect(await prepared.file.length(),
        lessThanOrEqualTo(PublicImageUploadPolicy.targetSizeBytes));
    final decoded = image.decodeJpg(await prepared.file.readAsBytes())!;
    expect(decoded.width, 600);
    expect(decoded.height, 600);
    await prepared.dispose();
    expect(await File(prepared.file.path).exists(), isFalse);
    expect(await source.length(), 12 * 1024 * 1024);
  });

  test('透明PNG处理保留透明度和尺寸，小图不会被重新编码', () async {
    final root = await Directory.systemTemp.createTemp('alpha-image-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/alpha.png');
    final pixels = image.Image(width: 100, height: 100, numChannels: 4);
    pixels.setPixelRgba(1, 1, 255, 0, 0, 128);
    await source.writeAsBytes(image.encodePng(pixels));
    final untouched = await PublicImageCompressor().prepare(XFile(source.path));
    expect(untouched.isTemporary, isFalse);
    final handle = await source.open(mode: FileMode.append);
    await handle.truncate(6 * 1024 * 1024);
    await handle.close();
    final prepared = await PublicImageCompressor().prepare(XFile(source.path));
    expect(prepared.file.mimeType, 'image/png');
    final decoded = image.decodePng(await prepared.file.readAsBytes())!;
    expect(decoded.getPixel(1, 1).a, 128);
    expect(decoded.width, 100);
    await prepared.dispose();
  });

  test('复杂JPEG根据实际输出逐阶段压缩并保留足够分辨率', () {
    final pixels = image.Image(width: 2400, height: 2400);
    var state = 7;
    for (final pixel in pixels) {
      state = (state * 1664525 + 1013904223) & 0xffffffff;
      pixel.setRgb(state & 255, (state >> 8) & 255, (state >> 16) & 255);
    }
    final original = Uint8List.fromList(image.encodeJpg(pixels, quality: 100));
    expect(
        original.length, greaterThan(PublicImageUploadPolicy.targetSizeBytes));
    final compressed = PublicImageCompressor.compressJpegBytes(original);
    expect(compressed.length,
        lessThanOrEqualTo(PublicImageUploadPolicy.targetSizeBytes));
    final decoded = image.decodeJpg(compressed)!;
    expect(decoded.width, inInclusiveRange(1800, 2400));
    expect(decoded.height, decoded.width);
  });

  test('超限动图不转成静态或直接发出，像素炸弹不解码', () async {
    final root = await Directory.systemTemp.createTemp('bounded-image-');
    addTearDown(() => root.delete(recursive: true));
    final gif = File('${root.path}/animation.gif');
    await gif.writeAsBytes([71, 73, 70, 56, 57, 97, 1, 0, 1, 0]);
    final handle = await gif.open(mode: FileMode.append);
    await handle.truncate(11 * 1024 * 1024);
    await handle.close();
    expect(() => PublicImageCompressor().prepare(XFile(gif.path)),
        throwsA(isA<PublicImagePreparationException>()));
    final huge = File('${root.path}/huge.jpg');
    await huge.writeAsBytes(_jpegHeader(width: 10000, height: 10000));
    expect(() => PublicImageCompressor().prepare(XFile(huge.path)),
        throwsA(isA<PublicImagePreparationException>()));
  });

  test('APNG在像素解码前识别，保留全部动画字节', () {
    final animation = image.Image(width: 2, height: 2, numChannels: 4);
    animation.addFrame(image.Image(width: 2, height: 2, numChannels: 4));
    final bytes = image.encodePng(animation);
    final compressed = PublicImageCompressor.compressPublicImageBytes(bytes);
    expect(compressed, orderedEquals(bytes));
    expect(image.PngDecoder().startDecode(compressed)!.numFrames, 2);
  });

  test('小于5MB手机旋转照片预先校正方向，服务端预览不会横躺', () async {
    final root = await Directory.systemTemp.createTemp('rotated-image-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/phone.jpg');
    final pixels = image.Image(width: 300, height: 200);
    pixels.exif.imageIfd.orientation = 6;
    await source.writeAsBytes(image.encodeJpg(pixels));
    final prepared = await PublicImageCompressor().prepare(XFile(source.path));
    expect(prepared.isTemporary, isTrue);
    final corrected = image.decodeJpg(await prepared.file.readAsBytes())!;
    expect(corrected.width, 200);
    expect(corrected.height, 300);
    expect(corrected.exif.imageIfd.orientation ?? 1, 1);
    await prepared.dispose();
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
