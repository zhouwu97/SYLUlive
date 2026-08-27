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

/// 统一公开 JPEG 的上传前压缩边界。
///
/// 这里只决定是否需要重编码，不处理文件 I/O 或平台压缩实现，便于将
/// GIF、透明 PNG 和私有媒体彻底排除在公开 JPEG 路径之外。
abstract final class PublicImageUploadPolicy {
  static const int maxDimension = 2048;
  static const int targetSizeBytes = 3 * 1024 * 1024;
  static const int jpegQuality = 85;

  static PublicImageCompressionDecision decide({
    required Uint8List bytes,
    required int fileSize,
  }) {
    final isJpeg = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    if (!isJpeg) {
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
      outputExtension: '.jpg',
    );
  }
}
