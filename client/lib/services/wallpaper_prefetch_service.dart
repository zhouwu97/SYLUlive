import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class WallpaperPrefetchService {
  static const String baseUrl =
      'https://sylulive.online/uploads/wallpapers/originals';
  static final Map<String, Future<void>> _activeDownloads = {};
  static const int _maxImageBytes = 20 * 1024 * 1024;

  /// 压缩文件大小和解码像素分别限额，避免小体积极端宽高图片绕过资源门槛。
  static const int maxInputPixels = 32 * 1000 * 1000;
  static const int maxDecodedPixels = 16 * 1000 * 1000;
  static const int maxDecodeDimension = 2560;
  static const int _maxMetadataBytes = 1024 * 1024;

  static const List<String> bundledWallpaperNames = [
    'tablet_landscape_01.png',
    'tablet_landscape_02.png',
    'tablet_landscape_03.png',
  ];

  static void start() {
    // 按需下载，启动时不常态化拉取平板横屏壁纸
  }

  static Future<String> localPathFor(String fileName) async {
    final appDir = await getApplicationDocumentsDirectory();
    return path.join(appDir.path, 'remote_$fileName');
  }

  static Future<bool> isValidImageFile(File file,
      {bool fullDecode = false}) async {
    try {
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length < 12 || length > _maxImageBytes) return false;
      final metadata = await _readImageMetadata(file);
      if (metadata == null) {
        // 保留已有的轻量魔数检查语义；完整校验必须拿到可用尺寸。
        return !fullDecode && await _hasSupportedMagic(file);
      }
      if (metadata.width <= 0 ||
          metadata.height <= 0 ||
          metadata.width * metadata.height > maxInputPixels) {
        return false;
      }
      if (!fullDecode) return true;

      final bytes = await file.readAsBytes();
      final target = _boundedDecodeSize(metadata.width, metadata.height);
      ui.Codec? codec;
      ui.Image? image;
      try {
        codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: target.width,
          targetHeight: target.height,
        );
        final frame = await codec.getNextFrame();
        image = frame.image;
        return image.width > 0 &&
            image.height > 0 &&
            image.width * image.height <= maxDecodedPixels;
      } finally {
        image?.dispose();
        codec?.dispose();
      }
    } catch (e) {
      debugPrint('Image validation failed: $e');
      return false;
    }
  }

  static File _verificationMarker(File image) => File('${image.path}.verified');

  static Future<bool> _isVerifiedCachedFile(File file) async {
    if (!await file.exists() || await file.length() <= 0) return false;
    final marker = _verificationMarker(file);
    if (!await marker.exists()) return false;
    try {
      final parts = (await marker.readAsString()).trim().split('|');
      if (parts.length != 4 ||
          parts[2] != '$maxInputPixels' ||
          parts[3] != '$maxDecodedPixels') {
        return false;
      }
      final recordedLength = int.tryParse(parts[0]);
      final recordedModified = int.tryParse(parts[1]);
      final stat = await file.stat();
      return recordedLength == await file.length() &&
          recordedModified == stat.modified.microsecondsSinceEpoch;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _writeVerificationMarker(File file) async {
    final stat = await file.stat();
    await _verificationMarker(file).writeAsString(
      '${await file.length()}|${stat.modified.microsecondsSinceEpoch}|$maxInputPixels|$maxDecodedPixels',
      flush: true,
    );
  }

  static Future<void> _deleteImageAndMarker(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    try {
      final marker = _verificationMarker(file);
      if (await marker.exists()) await marker.delete();
    } catch (_) {}
  }

  static Future<void> downloadAndVerifyImage(
    Dio dio,
    String url,
    String targetPath, {
    CancelToken? cancelToken,
  }) {
    if (_activeDownloads.containsKey(targetPath)) {
      return _activeDownloads[targetPath]!;
    }
    final future = _downloadAndVerifyImageInternal(
      dio,
      url,
      targetPath,
      cancelToken,
    );
    _activeDownloads[targetPath] = future;
    return future.whenComplete(() {
      _activeDownloads.remove(targetPath);
    });
  }

  static Future<void> _downloadAndVerifyImageInternal(
    Dio dio,
    String url,
    String targetPath,
    CancelToken? cancelToken,
  ) async {
    final tempFile = File('$targetPath.download');
    try {
      await _downloadAndVerifyImageCore(dio, url, targetPath, cancelToken);
    } catch (_) {
      await _deleteImageAndMarker(tempFile);
      rethrow;
    }
  }

  static Future<void> _downloadAndVerifyImageCore(
    Dio dio,
    String url,
    String targetPath,
    CancelToken? cancelToken,
  ) async {
    final targetFile = File(targetPath);

    // 如果已经存在且有效，则跳过
    if (await targetFile.exists() && await targetFile.length() > 0) {
      // 只有已完成过完整解码并留下校验标记的资源才走轻量魔数检查。
      // 旧版本或被外部替换过的文件会在这里补做一次完整校验。
      final verified = await _isVerifiedCachedFile(targetFile);
      if (verified && await isValidImageFile(targetFile)) {
        return;
      }
      final validExisting =
          await isValidImageFile(targetFile, fullDecode: true);
      if (validExisting) {
        await _writeVerificationMarker(targetFile);
        return;
      }
      debugPrint('Existing file $targetPath is invalid, deleting...');
      await _deleteImageAndMarker(targetFile);
    }

    final tempFile = File('$targetPath.download');

    final response = await dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(seconds: 30),
      ),
      cancelToken: cancelToken,
    );

    debugPrint('status: ${response.statusCode}');
    debugPrint('content-type: ${response.headers['content-type']}');
    final declaredLength = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    debugPrint('content-length: $declaredLength');

    if (response.statusCode != 200 || response.data == null) {
      throw Exception('Failed to download image: HTTP ${response.statusCode}');
    }

    if (declaredLength != null && declaredLength > _maxImageBytes) {
      throw Exception('Downloaded image exceeds the size limit');
    }
    var received = 0;
    final sink = tempFile.openWrite();
    try {
      await for (final chunk in response.data!.stream) {
        if (cancelToken?.isCancelled == true) {
          throw StateError('壁纸下载已取消');
        }
        received += chunk.length;
        if (received > _maxImageBytes) {
          cancelToken?.cancel('wallpaper_size_limit');
          throw Exception('Downloaded image exceeds the size limit');
        }
        sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    debugPrint('image path: ${tempFile.path}');
    debugPrint('exists: ${await tempFile.exists()}');
    debugPrint('size: ${await tempFile.length()}');

    final valid = await isValidImageFile(tempFile, fullDecode: true);
    debugPrint('valid image: $valid');

    if (!valid) {
      await _deleteImageAndMarker(tempFile);
      throw Exception('Downloaded file is not a valid image');
    }

    if (await targetFile.exists()) {
      await _deleteImageAndMarker(targetFile);
    }
    await tempFile.rename(targetFile.path);
    await _writeVerificationMarker(targetFile);
  }

  static Future<void> prefetchAll() async {
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
    try {
      for (final fileName in bundledWallpaperNames) {
        final savedPath = await localPathFor(fileName);
        try {
          await downloadAndVerifyImage(dio, '$baseUrl/$fileName', savedPath);
        } catch (e) {
          debugPrint('Wallpaper prefetch skipped $fileName: $e');
        }
      }
    } finally {
      dio.close(force: true);
    }
  }

  static Future<bool> _hasSupportedMagic(File file) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final header = await raf.read(12);
      return _supportedMagic(header);
    } finally {
      await raf.close();
    }
  }

  static bool _supportedMagic(List<int> header) {
    if (header.length < 12) return false;
    final isPng = header[0] == 0x89 &&
        header[1] == 0x50 &&
        header[2] == 0x4E &&
        header[3] == 0x47;
    final isJpg = header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF;
    final isGif = header[0] == 0x47 &&
        header[1] == 0x49 &&
        header[2] == 0x46 &&
        header[3] == 0x38;
    final isWebp = header[0] == 0x52 &&
        header[1] == 0x49 &&
        header[2] == 0x46 &&
        header[3] == 0x46 &&
        header[8] == 0x57 &&
        header[9] == 0x45 &&
        header[10] == 0x42 &&
        header[11] == 0x50;
    return isPng || isJpg || isGif || isWebp;
  }

  static Future<_ImageMetadata?> _readImageMetadata(File file) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final length = await file.length();
      final header = await raf.read(math.min(length, _maxMetadataBytes));
      if (!_supportedMagic(header)) return null;
      if (header.length >= 24 &&
          header[0] == 0x89 &&
          header[1] == 0x50 &&
          header[2] == 0x4E &&
          header[3] == 0x47) {
        return _ImageMetadata(
          _readUint32Be(header, 16),
          _readUint32Be(header, 20),
        );
      }
      if (header.length >= 10 &&
          header[0] == 0x47 &&
          header[1] == 0x49 &&
          header[2] == 0x46) {
        return _ImageMetadata(
          _readUint16Le(header, 6),
          _readUint16Le(header, 8),
        );
      }
      if (header.length >= 16 &&
          header[0] == 0x52 &&
          header[1] == 0x49 &&
          header[2] == 0x46 &&
          header[3] == 0x46) {
        return _readWebpMetadata(header);
      }
      if (header.length >= 3 &&
          header[0] == 0xFF &&
          header[1] == 0xD8 &&
          header[2] == 0xFF) {
        return _readJpegMetadata(header);
      }
      return null;
    } finally {
      await raf.close();
    }
  }

  static _ImageMetadata? _readJpegMetadata(List<int> bytes) {
    var offset = 2;
    while (offset + 9 < bytes.length) {
      while (offset < bytes.length && bytes[offset] != 0xFF) {
        offset++;
      }
      while (offset < bytes.length && bytes[offset] == 0xFF) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xD9 || marker == 0xDA) break;
      if (offset + 1 >= bytes.length) break;
      final segmentLength = _readUint16Be(bytes, offset);
      if (segmentLength < 2 || offset + segmentLength > bytes.length) break;
      final isSof = (marker >= 0xC0 && marker <= 0xC3) ||
          (marker >= 0xC5 && marker <= 0xC7) ||
          (marker >= 0xC9 && marker <= 0xCB) ||
          (marker >= 0xCD && marker <= 0xCF);
      if (isSof && offset + 7 < bytes.length) {
        return _ImageMetadata(
          _readUint16Be(bytes, offset + 5),
          _readUint16Be(bytes, offset + 3),
        );
      }
      offset += segmentLength;
    }
    return null;
  }

  static _ImageMetadata? _readWebpMetadata(List<int> bytes) {
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final chunk = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = _readUint32Le(bytes, offset + 4);
      final payload = offset + 8;
      if (payload + size > bytes.length) break;
      if (chunk == 'VP8X' && size >= 10) {
        return _ImageMetadata(
          1 +
              bytes[payload + 4] +
              (bytes[payload + 5] << 8) +
              (bytes[payload + 6] << 16),
          1 +
              bytes[payload + 7] +
              (bytes[payload + 8] << 8) +
              (bytes[payload + 9] << 16),
        );
      }
      if (chunk == 'VP8L' && size >= 5 && bytes[payload] == 0x2F) {
        final width = 1 +
            bytes[payload + 1] +
            ((bytes[payload + 2] & 0x3F) << 8) +
            ((bytes[payload + 3] & 0x03) << 14);
        final height = 1 +
            ((bytes[payload + 3] >> 2) & 0x3F) +
            ((bytes[payload + 4] & 0xFF) << 6);
        return _ImageMetadata(width, height);
      }
      if (chunk == 'VP8 ' && size >= 10 && bytes[payload + 3] == 0x9D) {
        return _ImageMetadata(
          _readUint16Le(bytes, payload + 6) & 0x3FFF,
          _readUint16Le(bytes, payload + 8) & 0x3FFF,
        );
      }
      offset = payload + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  static int _readUint16Be(List<int> bytes, int offset) =>
      (bytes[offset] << 8) | bytes[offset + 1];

  static int _readUint16Le(List<int> bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _readUint32Be(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _readUint32Le(List<int> bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

  static _DecodeSize _boundedDecodeSize(int width, int height) {
    var scale = 1.0;
    final longest = math.max(width, height);
    if (longest > maxDecodeDimension) {
      scale = maxDecodeDimension / longest;
    }
    final pixels = width * height * scale * scale;
    if (pixels > maxDecodedPixels) {
      scale *= math.sqrt(maxDecodedPixels / (width * height));
    }
    return _DecodeSize(
      math.max(1, (width * scale).floor()),
      math.max(1, (height * scale).floor()),
    );
  }
}

final class _ImageMetadata {
  const _ImageMetadata(this.width, this.height);

  final int width;
  final int height;
}

final class _DecodeSize {
  const _DecodeSize(this.width, this.height);

  final int width;
  final int height;
}
