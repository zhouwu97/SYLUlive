import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class WallpaperPrefetchService {
  static const String baseUrl = 'https://sylu.zhouwu.ccwu.cc/wallpapers';
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

  static void start() {}

  static Future<String> localPathFor(String fileName) async {
    final appDir = await getApplicationDocumentsDirectory();
    return path.join(appDir.path, 'remote_$fileName');
  }

  static Future<void> prefetchAll() async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ));

    for (final fileName in bundledWallpaperNames) {
      final savedPath = await localPathFor(fileName);
      final file = File(savedPath);
      if (await file.exists() && await file.length() > 0) continue;

      try {
        await dio.download('$baseUrl/$fileName', savedPath);
      } catch (e) {
        debugPrint('Wallpaper prefetch skipped $fileName: $e');
      }
    }
  }
}
