import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class WallpaperPrefetchService {
  static const String baseUrl =
      'http://156.233.229.232:8080/uploads/wallpapers/originals';
  static Future<void>? _prefetchTask;

  static const List<String> bundledWallpaperNames = [
    'phone_wallpaper_01.png',
    'phone_wallpaper_02.png',
    'phone_wallpaper_03.png',
    'phone_wallpaper_04.png',
    'tablet_landscape_01.png',
    'tablet_landscape_02.png',
    'tablet_landscape_03.png',
    'tablet_landscape_04.png',
    'tablet_landscape_05.png',
    'tablet_landscape_06.png',
    'tablet_landscape_07.png',
    'tablet_landscape_08.png',
  ];

  static void start() {
    if (kIsWeb) return;
    _prefetchTask ??= prefetchAll();
  }

  static Future<String> localPathFor(String fileName) async {
    final appDir = await getApplicationDocumentsDirectory();
    return path.join(appDir.path, 'remote_$fileName');
  }

  static Future<bool> isValidImageFile(File file) async {
    try {
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length <= 0) return false;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return false;
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
      Dio dio, String url, String targetPath) async {
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
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
    ));

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
