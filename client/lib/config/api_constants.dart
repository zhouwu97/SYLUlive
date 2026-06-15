import 'package:flutter/foundation.dart';

class ApiConstants {
  // 通过 --dart-define 注入 API 地址，例如：--dart-define=API_URL=http://localhost:8080/api
  // Web 生产环境默认走同源 /api，避免 HTTPS 页面请求明文 IP:8080 导致连接失败。
  static const String _configuredBaseUrl = String.fromEnvironment('API_URL');
  static String get baseUrl {
    if (_configuredBaseUrl.isNotEmpty) return _configuredBaseUrl;
    if (kIsWeb) return '/api';
    return 'http://156.233.229.232:8080/api';
  }

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
    return fullUrlForBase(path, baseUrl);
  }

  static String fullUrlForBase(String path, String url) {
    if (path.isEmpty) return '';
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final root = apiRootFromBaseUrl(url);
    if (root.isEmpty) return normalizedPath;
    return '$root$normalizedPath';
  }

  static String apiRootFromBaseUrl(String url) {
    final normalized = url.endsWith('/') && url.length > 1
        ? url.substring(0, url.length - 1)
        : url;
    if (normalized == '/api') return '';
    if (normalized.endsWith('/api')) {
      return normalized.substring(0, normalized.length - '/api'.length);
    }
    return normalized;
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
