import 'package:dio/dio.dart';

/// 主 App 的教务服务器访问闸门。
///
/// 身份验证使用 student-identity；阻断旧代理接口，避免凭据再次进入服务器长期存储。
final class AcademicServerAccessGuard extends Interceptor {
  const AcademicServerAccessGuard();

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    if (isAcademicServerPath(options)) {
      handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          message: '旧教务服务器接口已退役，请通过学生身份验证后在本机连接教务'));
      return;
    }
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
