import 'package:dio/dio.dart';

/// 主 App 的教务服务器访问闸门。
///
/// 本地教务使用独立的 JiaowuClient 和 CookieJar，不经过共享 Dio。生产
/// App 因此直接阻断共享 Dio 上的所有 `/edu/*` 请求，避免旧页面或旧兼容
/// 代码绕过本机数据源再次访问教务服务器。
final class AcademicServerAccessGuard extends Interceptor {
  const AcademicServerAccessGuard();

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    if (isAcademicServerPath(options)) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          message: '教务服务器接口已阻断，请使用本机直连教务',
        ),
      );
      return;
    }
    handler.next(options);
  }

  /// 同时兼容 Dio 的相对 path 和已拼接 `/api` 前缀的 URI path。
  static bool isAcademicServerPath(RequestOptions options) {
    bool matches(String path) =>
        path == '/edu' ||
        path.startsWith('/edu/') ||
        path == '/api/edu' ||
        path.startsWith('/api/edu/');

    return matches(options.path) || matches(options.uri.path);
  }
}
