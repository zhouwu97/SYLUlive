import 'dart:typed_data';

import 'image_header_size_parser.dart';

/// 公开图片上传前的压缩判定结果。
class PublicImageCompressionDecision {
  const PublicImageCompressionDecision({
    required this.shouldCompress,
    required this.maxDimension,
    required this.quality,
    required this.outputExtension,
  });

  final bool shouldCompress;
  final int maxDimension;
  final int quality;
  final String outputExtension;
}

/// 公开图约 5MiB 的柔性目标，10MiB 上传硬限；PNG 保留透明，GIF 保留动画。
abstract final class PublicImageUploadPolicy {
  static const int maxDimension = 12000;
  static const int maxPixels = 50 * 1000 * 1000;
  static const int targetSizeBytes = 5 * 1024 * 1024;
  static const int maxUploadSizeBytes = 10 * 1024 * 1024;
  static const int maxInputSizeBytes = 100 * 1024 * 1024;
  static const int jpegQuality = 94;

  static PublicImageCompressionDecision decide({
    required Uint8List bytes,
    required int fileSize,
  }) {
    final isJpeg = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    final isPng = bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
    if (!isJpeg && !isPng) {
      return const PublicImageCompressionDecision(
        shouldCompress: false,
        maxDimension: maxDimension,
        quality: jpegQuality,
        outputExtension: '',
      );
    }

    final dimensions = ImageHeaderSizeParser.parseBytesSize(bytes);
    final longestEdge = dimensions == null
        ? maxDimension + 1
        : dimensions.width > dimensions.height
            ? dimensions.width
            : dimensions.height;
    final shouldCompress =
        longestEdge > maxDimension || fileSize > targetSizeBytes;

    return PublicImageCompressionDecision(
      shouldCompress: shouldCompress,
      maxDimension: maxDimension,
      quality: jpegQuality,
      outputExtension: isPng ? '.png' : '.jpg',
    );
  }
}
