import 'package:flutter/foundation.dart';

class ApiConstants {
  // 通过 --dart-define 注入 API 地址，例如：--dart-define=API_URL=http://localhost:8080/api
  static const String baseUrl = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://156.233.229.232:8080/api',
  );

  // Python 教务服务（绑定、课表、成绩）
  static const String eduServiceUrl = String.fromEnvironment(
    'EDU_URL',
    defaultValue: 'http://101.42.27.44:8000',
  );

  // 极光推送 AppKey
  static const String jpushAppKey = String.fromEnvironment(
    'JPUSH_APP_KEY',
    defaultValue: '', // 必须通过 --dart-define 注入
  );

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
