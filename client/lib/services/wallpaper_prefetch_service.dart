import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class WallpaperPrefetchService {
  static const String baseUrl =
      'https://sylulive.online/uploads/wallpapers/originals';
  static Future<void>? _prefetchTask;
  static final Map<String, Future<void>> _activeDownloads = {};

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

  static Future<bool> isValidImageFile(File file, {bool fullDecode = false}) async {
    try {
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length < 12) return false;

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
      if (await isValidImageFile(targetFile)) {
        return;
      } else {
        debugPrint('Existing file $targetPath is invalid, deleting...');
        try {
          await targetFile.delete();
        } catch (_) {}
      }
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

    await tempFile.writeAsBytes(response.data!, flush: true);

    debugPrint('image path: ${tempFile.path}');
    debugPrint('exists: ${await tempFile.exists()}');
    debugPrint('size: ${await tempFile.length()}');

    final valid = await isValidImageFile(tempFile);
    debugPrint('valid image: $valid');

    if (!valid) {
      try {
        await tempFile.delete();
      } catch (_) {}
      throw Exception('Downloaded file is not a valid image');
    }

    if (await targetFile.exists()) {
      try {
        await targetFile.delete();
      } catch (_) {}
    }
    await tempFile.rename(targetFile.path);
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
