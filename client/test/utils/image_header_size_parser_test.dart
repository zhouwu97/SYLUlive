import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/image_header_size_parser.dart';

void main() {
  group('ImageHeaderSizeParser Tests', () {
    test('PNG header parses width and height correctly', () {
      final bytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
        0x00, 0x00, 0x04, 0x38, // width = 1080
        0x00, 0x00, 0x07, 0x80, // height = 1920
        0x08, 0x06, 0x00, 0x00, 0x00,
      ]);
      final size = ImageHeaderSizeParser.parseBytesSize(bytes);
      expect(size, isNotNull);
      expect(size!.width, 1080);
      expect(size.height, 1920);
    });

    test('GIF89a header parses width and height correctly', () {
      final bytes = Uint8List.fromList([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
        0xF4, 0x01, // width = 500 (little endian)
        0x2C, 0x01, // height = 300 (little endian)
        0x70, 0x00, 0x00,
      ]);
      final size = ImageHeaderSizeParser.parseBytesSize(bytes);
      expect(size, isNotNull);
      expect(size!.width, 500);
      expect(size.height, 300);
    });

    test('JPEG header parses SOF0 marker width and height', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01,
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // APP0
        0xFF, 0xC0, // SOF0
        0x00, 0x11, // length = 17
        0x08, // precision
        0x02, 0x80, // height = 640 (big endian)
        0x03, 0x20, // width = 800 (big endian)
        0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
      ]);
      final size = ImageHeaderSizeParser.parseBytesSize(bytes);
      expect(size, isNotNull);
      expect(size!.width, 800);
      expect(size.height, 640);
    });

    test('WebP VP8X header parses extended dimensions', () {
      final bytes = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46, // RIFF
        0x24, 0x00, 0x00, 0x00,
        0x57, 0x45, 0x42, 0x50, // WEBP
        0x56, 0x50, 0x38, 0x58, // VP8X
        0x0A, 0x00, 0x00, 0x00,
        0x10, 0x00, 0x00, 0x00,
        0xE7, 0x03, 0x00, // width - 1 = 999 -> 1000
        0xCF, 0x07, 0x00, // height - 1 = 1999 -> 2000
      ]);
      final size = ImageHeaderSizeParser.parseBytesSize(bytes);
      expect(size, isNotNull);
      expect(size!.width, 1000);
      expect(size.height, 2000);
    });

    test('Corrupted or short header returns null without throwing', () {
      expect(ImageHeaderSizeParser.parseBytesSize(Uint8List.fromList([1, 2, 3])), isNull);
      expect(ImageHeaderSizeParser.parseBytesSize(Uint8List(0)), isNull);
      expect(ImageHeaderSizeParser.parseBytesSize(Uint8List.fromList([0xFF, 0xD8, 0x00, 0x00])), isNull);
    });
  });
}
