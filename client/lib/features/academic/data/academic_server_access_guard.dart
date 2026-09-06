import 'package:dio/dio.dart';

/// 主 App 的教务服务器访问闸门。
///
/// 服务端保存教务授权并负责会话恢复，客户端通过共享 Dio 访问教务 API。
/// 教务凭据不会进入客户端持久化存储。
final class AcademicServerAccessGuard extends Interceptor {
  const AcademicServerAccessGuard();

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    handler.next(options);
  }

  /// 同时兼容 Dio 的相对 path 和已拼接 `/api` 前缀的 URI path。
  static bool isAcademicServerPath(RequestOptions options) {
    const retiredAuthPaths = {
      '/register_with_edu',
      '/api/register_with_edu',
      '/login_edu',
      '/api/login_edu',
      '/forgot_password',
      '/api/forgot_password',
      '/password/edu/reset',
      '/api/password/edu/reset',
    };

    bool matches(String path) {
      final normalized = path.length > 1 && path.endsWith('/')
          ? path.substring(0, path.length - 1)
          : path;
      return normalized == '/edu' ||
          normalized.startsWith('/edu/') ||
          normalized == '/api/edu' ||
          normalized.startsWith('/api/edu/') ||
          retiredAuthPaths.contains(normalized);
    }

    return matches(options.path) || matches(options.uri.path);
  }
}
