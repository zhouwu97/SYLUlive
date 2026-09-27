import 'dart:io';
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

      // 快速头部魔数校验，避免主线程频繁完整解码图片
      final raf = await file.open(mode: FileMode.read);
      final header = List<int>.filled(12, 0);
      final readBytes = await raf.readInto(header, 0, 12);
      await raf.close();

      if (readBytes < 12) return false;

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

      if (!isPng && !isJpg && !isGif && !isWebp) {
        return false;
      }

      if (!fullDecode) {
        return true;
      }

      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final valid = frame.image.width > 0 && frame.image.height > 0;
      frame.image.dispose();
      codec.dispose();
      return valid;
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
      if (parts.length != 2) return false;
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
      '${await file.length()}|${stat.modified.microsecondsSinceEpoch}',
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
    String targetPath,
  ) {
    if (_activeDownloads.containsKey(targetPath)) {
      return _activeDownloads[targetPath]!;
    }
    final future = _downloadAndVerifyImageInternal(dio, url, targetPath);
    _activeDownloads[targetPath] = future;
    return future.whenComplete(() {
      _activeDownloads.remove(targetPath);
    });
  }

  static Future<void> _downloadAndVerifyImageInternal(
    Dio dio,
    String url,
    String targetPath,
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

    // 使用 bytes 接收以获取 header 和内容
    final response = await dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 30),
      ),
    );

    debugPrint('status: ${response.statusCode}');
    debugPrint('content-type: ${response.headers['content-type']}');
    debugPrint('content-length: ${response.data?.length}');

    if (response.statusCode != 200 || response.data == null) {
      throw Exception('Failed to download image: HTTP ${response.statusCode}');
    }

    if (response.data!.length > _maxImageBytes) {
      await _deleteImageAndMarker(tempFile);
      throw Exception('Downloaded image exceeds the size limit');
    }
    await tempFile.writeAsBytes(response.data!, flush: true);

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

    for (final fileName in bundledWallpaperNames) {
      final savedPath = await localPathFor(fileName);
      try {
        await downloadAndVerifyImage(dio, '$baseUrl/$fileName', savedPath);
      } catch (e) {
        debugPrint('Wallpaper prefetch skipped $fileName: $e');
      }
    }
  }
}
