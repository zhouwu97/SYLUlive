import 'package:flutter/material.dart';

/// 校园大图预热入口，确保首页与地图页使用同一个图片缓存键。
class CampusAssetPreloader {
  CampusAssetPreloader._();

  static const mapImage = ResizeImage(
    AssetImage('assets/images/map.png'),
    width: 3072,
  );

  static bool _mapWarmed = false;

  static Future<void> warmMap(BuildContext context) async {
    if (_mapWarmed) return;
    _mapWarmed = true;

    try {
      await precacheImage(mapImage, context);
    } catch (_) {
      // 预热失败不影响地图页自行加载，允许下次回到校园页时重试。
      _mapWarmed = false;
    }
  }
}
