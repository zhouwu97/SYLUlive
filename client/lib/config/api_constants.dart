import 'package:flutter/foundation.dart';

class ApiConstants {
  // Web 端必须走 HTTPS 域名避免跨域/混合内容，App 端直接连服务器 IP 绕过 Web 代理的大小限制
  static const String baseUrl = kIsWeb 
      ? 'https://sylu.zhouwu.ccwu.cc/api'
      : 'http://156.233.229.232:8080/api';
      
  // Python 教务服务（绑定、课表、成绩）
  static const String eduServiceUrl = 'http://101.42.27.44:8000';

  /// 将服务端返回的相对路径转为完整 URL
  static String fullUrl(String path) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final root = baseUrl.replaceAll('/api', '');
    return '$root$path';
  }

  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
  static const int maxRetries = 3;
}

class StorageKeys {
  static const String authToken = 'auth_token';
  static const String authUser = 'auth_user';
  static const String themeMode = 'theme_mode';
}
