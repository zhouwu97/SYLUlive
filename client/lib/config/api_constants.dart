import 'package:flutter/foundation.dart';

class ApiConstants {
  // Web 与 App 使用不同的编译参数，避免网页和 App 误用对方的接口入口。
  // Web: --dart-define=WEB_API_URL=/api
  // App: --dart-define=APP_API_URL=https://sylulive.online/api
  // 生产 App 默认走 HTTPS 域名；Web 默认走同源反代。
  static const String _webBaseUrl = String.fromEnvironment('WEB_API_URL');
  static const String _appBaseUrl = String.fromEnvironment('APP_API_URL');
  static const String _legacyBaseUrl = String.fromEnvironment('API_URL');
  static const String _defaultAppBaseUrl = 'https://sylulive.online/api';
  static const String stickerAssetVersion = '20260729-1';

  static String get baseUrl {
    if (kIsWeb) return _webBaseUrl.isNotEmpty ? _webBaseUrl : '/api';
    if (_appBaseUrl.isNotEmpty) return _appBaseUrl;
    if (_legacyBaseUrl.isNotEmpty) return _legacyBaseUrl;
    return _defaultAppBaseUrl;
  }

  // 极光推送 AppKey
  static const String jpushAppKey = String.fromEnvironment(
    'JPUSH_APP_KEY',
    defaultValue: 'fbbd87f741e919f39519afe6', // 避免本地调试忘传导致初始化失败
  );

  /// 将服务端返回的相对路径转为完整 URL
  static String fullUrl(String path) {
    final normalizedPath = normalizeWebResourceUrl(path);
    return fullUrlForBase(versionStickerResourceUrl(normalizedPath), baseUrl);
  }

  static String versionStickerResourceUrl(String path) {
    final uri = Uri.tryParse(path.trim());
    if (uri == null || uri.hasScheme || !uri.path.startsWith('/stickers/')) {
      return path;
    }
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        'v': stickerAssetVersion,
      },
    ).toString();
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

  // 普通接口使用短连接/接收超时，避免弱网下页面长时间像“点坏了”。
  // 上传、AI 流式请求等长请求必须在调用点用 Options 覆盖这些默认值。
  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration receiveTimeout = Duration(seconds: 20);
  static const Duration sendTimeout = Duration(seconds: 20);
  static const int maxRetries = 2;

  // Public alias for announcements. Some mobile networks stall plaintext
  // direct-IP requests whose path contains "announcement".
  static const String noticesPath = '/notices';

  // Feed 用户控制与事件采集（FEED-1 / FEED-2 / FEED-3）。
  static String feedNotInterestedPath(int postId) =>
      '/feed/posts/$postId/not-interested';
  static String feedHiddenAuthorPath(int authorId) =>
      '/feed/authors/$authorId/hidden';
  static const String feedEventsBatchPath = '/feed/events/batch';
}

class StorageKeys {
  static const String authToken = 'auth_token';
  static const String authUser = 'auth_user';
  static const String themeMode = 'theme_mode';
}
