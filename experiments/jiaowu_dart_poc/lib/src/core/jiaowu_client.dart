import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../api/profile_api.dart';
import '../auth/jiaowu_auth.dart';
import '../core/jiaowu_endpoints.dart';
import '../error/jiaowu_exception.dart';
import '../model/login_result.dart';
import '../model/student_profile.dart';
import '../session/jiaowu_session.dart';

/// 纯 Dart 教务客户端门面。
///
/// 一个实例就是一个教务 Session：Dio、CookieJar、登录探活和后续接口必须
/// 从这里共享，调用方不应为每个接口新建客户端。
final class JiaowuClient {
  JiaowuClient({
    String baseUrl = JiaowuEndpoints.defaultBaseUrl,
    Duration timeout = const Duration(seconds: 8),
    Dio? dio,
    CookieJar? cookieJar,
    JiaowuSession? session,
  })  : dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: timeout,
                receiveTimeout: timeout,
                followRedirects: false,
                // 必须保留 302/901 给协议分类器，不让 Dio 先抛错。
                validateStatus: (status) =>
                    status != null && status >= 200 && status < 600,
              ),
            ),
        cookieJar = cookieJar ?? CookieJar(),
        session = session ?? JiaowuSession() {
    this.dio.options.baseUrl = baseUrl;
    this.dio.options.connectTimeout = timeout;
    this.dio.options.receiveTimeout = timeout;
    this.dio.options.followRedirects = false;
    this.dio.options.validateStatus =
        (status) => status != null && status >= 200 && status < 600;

    // CookieManager 负责请求前加载、响应后合并 Set-Cookie。
    this.dio.interceptors.add(CookieManager(this.cookieJar));
    auth = JiaowuAuth(
      dio: this.dio,
      cookieJar: this.cookieJar,
      session: this.session,
    );
    profileApi = ProfileApi(dio: this.dio, session: this.session);
  }

  final Dio dio;
  final CookieJar cookieJar;
  final JiaowuSession session;
  late final JiaowuAuth auth;
  late final ProfileApi profileApi;

  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) {
    return auth.login(studentId: studentId, password: password);
  }

  Future<String> getCsrfToken() => auth.getCsrfToken();

  Future<StudentProfile> getProfile() => profileApi.fetch();

  /// 主动退出或切换账号时清理完整 HTTP 会话。
  Future<void> resetSession() => session.resetSession(cookieJar);

  /// 释放底层连接。CookieJar 不会被写入磁盘。
  void close({bool force = false}) {
    dio.close(force: force);
  }
}

/// 让公共入口仍暴露教务异常类型，避免调用方需要知道内部目录结构。
typedef JiaowuError = JiaowuException;
