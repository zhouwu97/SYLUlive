import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';

import 'image_header_size_parser.dart';
import 'public_image_upload_policy.dart';

typedef JpegBytesCompressor = Uint8List Function(Uint8List source);

class PublicImagePreparationException implements Exception {
  const PublicImagePreparationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 上传结束后清理处理副本；用户选择的原始文件不变。
class PreparedPublicImage {
  const PreparedPublicImage({required this.file, required this.isTemporary});
  final XFile file;
  final bool isTemporary;

  Future<void> dispose() async {
    if (!isTemporary || file.path.isEmpty) return;
    try {
      await File(file.path).delete();
      final parent = File(file.path).parent;
      if (await parent.exists()) await parent.delete();
    } catch (_) {
      // 清理失败不改变上传结果。
    }
  }
}

/// 先保分辨率调整编码，再按实际体积缩图；不以原始文件大小猜测内容复杂度。
class PublicImageCompressor {
  PublicImageCompressor({JpegBytesCompressor? compress})
      : _compress = compress ?? compressPublicImageBytes;
  final JpegBytesCompressor _compress;

  // 网络可并发，解码串行且离开 UI isolate，避免九张高像素图同时占满内存。
  static Future<void> _processing = Future<void>.value();

  Future<PreparedPublicImage> prepare(XFile source,
      {bool Function()? shouldContinue}) async {
    void checkActive() {
      if (shouldContinue?.call() == false) {
        throw const PublicImagePreparationException('图片上传已取消');
      }
    }

    checkActive();
    final diskFile = File(source.path);
    final onDisk = source.path.isNotEmpty && await diskFile.exists();
    final fileSize = onDisk ? await diskFile.length() : await source.length();
    if (fileSize > PublicImageUploadPolicy.maxInputSizeBytes) {
      throw const PublicImagePreparationException('单张图片超过 100MB，请先裁剪或导出后选择');
    }
    final header =
        onDisk ? await _readHeader(diskFile) : await source.readAsBytes();
    final dimensions = ImageHeaderSizeParser.parseBytesSize(header);
    if (dimensions != null &&
        dimensions.width * dimensions.height >
            PublicImageUploadPolicy.maxPixels) {
      throw const PublicImagePreparationException('图片像素过高，请先裁剪或分成多张图片');
    }
    final decision =
        PublicImageUploadPolicy.decide(bytes: header, fileSize: fileSize);
    final orientation = header.length >= 2 && header[0] == 0xff && header[1] == 0xd8
        ? image.decodeJpgExif(header)?.imageIfd.orientation ?? 1 : 1;
    final needsOrientation = orientation >= 2 && orientation <= 8;
    if (!decision.shouldCompress && !needsOrientation) {
      _checkUploadSize(fileSize);
      return PreparedPublicImage(file: source, isTemporary: false);
    }

    Uint8List compressed;
    try {
      final task = _processing.then((_) async {
        checkActive();
        final bytes =
            onDisk ? await diskFile.readAsBytes() : await source.readAsBytes();
        checkActive();
        return compute(_compress, bytes);
      });
      _processing =
          task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
      compressed = await task;
      checkActive();
      if (compressed.isEmpty) throw const FormatException('图片处理失败');
    } on PublicImagePreparationException {
      rethrow;
    } catch (_) {
      _checkUploadSize(fileSize);
      if (dimensions != null &&
          dimensions.longestSide > PublicImageUploadPolicy.maxDimension) {
        throw const PublicImagePreparationException('图片处理失败，请裁剪图片后重试');
      }
      return PreparedPublicImage(file: source, isTemporary: false);
    }
    _checkUploadSize(compressed.length);
    if (!needsOrientation && compressed.length >= fileSize &&
        (dimensions?.longestSide ?? double.infinity) <=
            PublicImageUploadPolicy.maxDimension) {
      return PreparedPublicImage(file: source, isTemporary: false);
    }

    final tempDir =
        await Directory.systemTemp.createTemp('sylulive-public-image-');
    try {
      final extension = decision.outputExtension;
      final output =
          File('${tempDir.path}${Platform.pathSeparator}image$extension');
      await output.writeAsBytes(compressed, flush: true);
      final stem = source.name.trim().replaceAll(RegExp(r'\.[^.]+$'), '');
      return PreparedPublicImage(
        file: XFile(output.path,
            name: '${stem.isEmpty ? 'upload' : stem}$extension',
            mimeType: extension == '.png' ? 'image/png' : 'image/jpeg'),
        isTemporary: true,
      );
    } catch (_) {
      await tempDir.delete(recursive: true);
      rethrow;
    }
  }

  static void _checkUploadSize(int size) {
    if (size > PublicImageUploadPolicy.maxUploadSizeBytes) {
      throw const PublicImagePreparationException(
        '图片处理后仍超过 10MB；为保留动画、透明度或细节，请裁剪、分图或导出后重试',
      );
    }
  }

  static Uint8List compressJpegBytes(Uint8List source) =>
      compressPublicImageBytes(source);

  static Uint8List compressPublicImageBytes(Uint8List source) {
    final dimensions = ImageHeaderSizeParser.parseBytesSize(source);
    if (dimensions == null ||
        dimensions.width * dimensions.height >
            PublicImageUploadPolicy.maxPixels) {
      throw const FormatException('图片尺寸无效或像素过高');
    }
    final isPng = source[0] == 0x89;
    if (isPng) {
      final info = image.PngDecoder().startDecode(source);
      if (info == null) throw const FormatException('PNG 解码失败');
      if (info.numFrames > 1) {
        if (dimensions.longestSide > PublicImageUploadPolicy.maxDimension) {
          throw const PublicImagePreparationException('动图尺寸过大，请缩小动图尺寸或分图后重试');
        }
        return source;
      }
    }
    final decoded =
        isPng ? image.decodePng(source, frame: 0) : image.decodeJpg(source);
    if (decoded == null) throw const FormatException('图片解码失败');
    // APNG 的动画不能因公开上传而变成首帧。
    if (decoded.numFrames > 1) return source;
    var current = image.bakeOrientation(decoded);
    final longest = math.max(current.width, current.height);
    if (longest > PublicImageUploadPolicy.maxDimension) {
      current =
          _resize(current, PublicImageUploadPolicy.maxDimension / longest);
    }
    Uint8List? best;
    for (var step = 0; step < 5; step++) {
      for (final quality in isPng ? [100] : [94, 90, 86, 82]) {
        final encoded = isPng
            ? image.encodePng(current, level: 9)
            : image.encodeJpg(current, quality: quality);
        final candidate = Uint8List.fromList(encoded);
        if (best == null || candidate.length < best.length) best = candidate;
        if (candidate.length <= PublicImageUploadPolicy.targetSizeBytes) {
          return candidate;
        }
      }
      // 透明 PNG 在 10MB 内优先保留像素；5MB 是目标，不强行为它模糊文字。
      if (isPng && best!.length <= PublicImageUploadPolicy.maxUploadSizeBytes) {
        return best;
      }
      final ratio =
          math.sqrt(PublicImageUploadPolicy.targetSizeBytes / best!.length);
      current = _resize(current, ratio.clamp(0.65, 0.9));
    }
    return best!;
  }

  static image.Image _resize(image.Image source, double ratio) =>
      image.copyResize(
        source,
        width: math.max(1, (source.width * ratio).round()),
        height: math.max(1, (source.height * ratio).round()),
        interpolation: image.Interpolation.average,
      );

  static Future<Uint8List> _readHeader(File file) async {
    final handle = await file.open(mode: FileMode.read);
    try {
      final length = await handle.length();
      return await handle.read(math.min(length, 64 * 1024));
    } finally {
      await handle.close();
    }
  }
}
