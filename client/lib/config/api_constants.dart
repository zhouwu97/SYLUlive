import 'package:flutter/foundation.dart';

class ApiConstants {
  // Web 与 App 使用不同的编译参数，避免网页和 App 误用对方的接口入口。
  // Web: --dart-define=WEB_API_URL=/api
  // App: --dart-define=APP_API_URL=http://156.233.229.232:8080/api
  // 生产 App 默认直连服务器 IP；Web 默认走同源反代。
  static const String _webBaseUrl = String.fromEnvironment('WEB_API_URL');
  static const String _appBaseUrl = String.fromEnvironment('APP_API_URL');
  static const String _legacyBaseUrl = String.fromEnvironment('API_URL');
  static const String _defaultAppBaseUrl = 'http://156.233.229.232:8080/api';

  static String get baseUrl {
    if (kIsWeb) return _webBaseUrl.isNotEmpty ? _webBaseUrl : '/api';
    if (_appBaseUrl.isNotEmpty) return _appBaseUrl;
    if (_legacyBaseUrl.isNotEmpty) return _legacyBaseUrl;
    return _defaultAppBaseUrl;
  }

  // 极光推送 AppKey
  static const String jpushAppKey = String.fromEnvironment(
    'JPUSH_APP_KEY',
    defaultValue: '', // 必须通过 --dart-define 注入
  );

  /// 将服务端返回的相对路径转为完整 URL
  static String fullUrl(String path) {
    return fullUrlForBase(normalizeWebResourceUrl(path), baseUrl);
  }

  static String normalizeWebResourceUrl(String path) {
    if (!kIsWeb) return path;
    return normalizeSameOriginResourceUrl(path);
  }

  static String normalizeSameOriginResourceUrl(String path) {
    final uri = Uri.tryParse(path.trim());
    if (uri == null || !uri.hasScheme || uri.scheme != 'http') return path;
    if (!uri.path.startsWith('/uploads/')) return path;

    final buffer = StringBuffer(uri.path);
    if (uri.hasQuery) buffer.write('?${uri.query}');
    if (uri.hasFragment) buffer.write('#${uri.fragment}');
    return buffer.toString();
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
  static const Duration sendTimeout = Duration(seconds: 30);
  static const int maxRetries = 3;

  // Public alias for announcements. Some mobile networks stall plaintext
  // direct-IP requests whose path contains "announcement".
  static const String noticesPath = '/notices';
}

class StorageKeys {
  static const String authToken = 'auth_token';
  static const String authUser = 'auth_user';
  static const String themeMode = 'theme_mode';
}
