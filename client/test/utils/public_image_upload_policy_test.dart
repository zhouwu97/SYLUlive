import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/public_image_upload_policy.dart';

void main() {
  group('PublicImageUploadPolicy', () {
    test('尺寸和体积均在限制内的 JPEG 不重复编码', () {
      final decision = PublicImageUploadPolicy.decide(
        bytes: _jpegHeader(width: 2048, height: 1200),
        fileSize: 3 * 1024 * 1024,
      );

      expect(decision.shouldCompress, isFalse);
      expect(decision.outputExtension, '.jpg');
    });

    test('超过最长边限制的 JPEG 需要按公开上传配方压缩', () {
      final decision = PublicImageUploadPolicy.decide(
        bytes: _jpegHeader(width: 3000, height: 1200),
        fileSize: 1024,
      );

      expect(decision.shouldCompress, isTrue);
      expect(decision.maxDimension, 2048);
      expect(decision.quality, 85);
    });

    test('超过目标体积的 JPEG 即使尺寸合格也需要压缩', () {
      final decision = PublicImageUploadPolicy.decide(
        bytes: _jpegHeader(width: 1600, height: 1200),
        fileSize: 3 * 1024 * 1024 + 1,
      );

      expect(decision.shouldCompress, isTrue);
    });

    test('透明 PNG 与 GIF 不进入 JPEG 压缩路径', () {
      final png = Uint8List.fromList(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0,
        0,
        0,
        13,
        0x49,
        0x48,
        0x44,
        0x52,
        0,
        0,
        0x10,
        0,
        0,
        0,
        0x10,
        8,
        6,
        0,
        0,
        0,
      ]);
      final gif = Uint8List.fromList(<int>[
        0x47,
        0x49,
        0x46,
        0x38,
        0x39,
        0x61,
        1,
        0,
        1,
        0,
      ]);

      expect(
        PublicImageUploadPolicy.decide(bytes: png, fileSize: 9 * 1024 * 1024)
            .shouldCompress,
        isFalse,
      );
      expect(
        PublicImageUploadPolicy.decide(bytes: gif, fileSize: 9 * 1024 * 1024)
            .shouldCompress,
        isFalse,
      );
    });
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
