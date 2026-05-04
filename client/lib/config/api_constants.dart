class ApiConstants {
  // Go 服务器（帖子、用户、消息等）
  static const String baseUrl = 'http://156.233.229.232:8080/api';
  // Python 教务服务（绑定、课表、成绩）
  static const String eduServiceUrl = 'http://101.42.27.44:8000';

  /// 将服务端返回的相对路径转为完整 URL
  /// 如 /uploads/ab/cd.jpg → http://156.233.229.232:8080/uploads/ab/cd.jpg
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
