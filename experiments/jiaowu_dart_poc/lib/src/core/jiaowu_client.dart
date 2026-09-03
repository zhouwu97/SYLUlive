import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import '../api/course_api.dart';
import '../api/grade_api.dart';
import '../api/grade_detail_api.dart';
import '../api/profile_api.dart';
import '../auth/jiaowu_auth.dart';
import '../core/jiaowu_endpoints.dart';
import '../error/jiaowu_exception.dart';
import '../model/captcha_challenge.dart';
import '../model/login_result.dart';
import '../model/course_fetch_result.dart';
import '../model/grade_fetch_result.dart';
import '../model/grade_detail.dart';
import '../model/student_profile.dart';
import '../network/jiaowu_trust_chain.dart';
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
  })  : dio = dio ?? _createDefaultDio(baseUrl: baseUrl, timeout: timeout),
        cookieJar = cookieJar ?? CookieJar(),
        session = session ?? JiaowuSession() {
    this.dio.options.baseUrl = baseUrl;
    this.dio.options.connectTimeout = timeout;
    this.dio.options.receiveTimeout = timeout;
    this.dio.options.followRedirects = false;
    this.dio.options.validateStatus = (status) =>
        status != null && ((status >= 200 && status < 600) || status == 901);

    // CookieManager 负责请求前加载、响应后合并 Set-Cookie。
    this.dio.interceptors.add(CookieManager(this.cookieJar));
    auth = JiaowuAuth(
      dio: this.dio,
      cookieJar: this.cookieJar,
      session: this.session,
    );
    profileApi = ProfileApi(dio: this.dio, session: this.session);
    courseApi = CourseApi(dio: this.dio, session: this.session);
    gradeApi = GradeApi(dio: this.dio, session: this.session);
    gradeDetailApi = GradeDetailApi(dio: this.dio, session: this.session);
  }

  static Dio _createDefaultDio({
    required String baseUrl,
    required Duration timeout,
  }) {
    final useBundledIntermediate = Uri.tryParse(baseUrl)?.host ==
        Uri.parse(JiaowuEndpoints.defaultBaseUrl).host;
    final client = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: timeout,
        receiveTimeout: timeout,
        followRedirects: false,
        // 必须保留 302/901 给协议分类器，不让 Dio 先抛错。
        validateStatus: (status) =>
            status != null &&
            ((status >= 200 && status < 600) || status == 901),
      ),
    );
    client.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => JiaowuTrustChain.createHttpClient(
        useBundledIntermediate: useBundledIntermediate,
      ),
    );
    return client;
  }

  final Dio dio;
  final CookieJar cookieJar;
  final JiaowuSession session;
  late final JiaowuAuth auth;
  late final ProfileApi profileApi;
  late final CourseApi courseApi;
  late final GradeApi gradeApi;
  late final GradeDetailApi gradeDetailApi;

  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) {
    return auth.login(studentId: studentId, password: password);
  }

  Future<String> getCsrfToken() => auth.getCsrfToken();

  Future<CaptchaChallenge> getCaptchaChallenge() => auth.getCaptchaChallenge();

  Future<LoginResult> continueLoginWithCaptcha({required String code}) =>
      auth.continueLoginWithCaptcha(code: code);

  Future<StudentProfile> getProfile() => profileApi.fetch();

  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
    Duration totalBudget = const Duration(seconds: 12),
  }) {
    return courseApi.fetch(
      year: year,
      semester: semester,
      totalBudget: totalBudget,
    );
  }

  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
    Duration totalBudget = const Duration(seconds: 20),
    int maxPages = GradeApi.defaultMaxPages,
  }) {
    return gradeApi.fetch(
      year: year,
      semester: semester,
      totalBudget: totalBudget,
      maxPages: maxPages,
    );
  }

  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
    Duration timeout = const Duration(seconds: 8),
  }) {
    return gradeDetailApi.fetch(
      year: year,
      semester: semester,
      classId: classId,
      courseName: courseName,
      courseId: courseId,
      studentGradeId: studentGradeId,
      timeout: timeout,
    );
  }

  /// 主动退出或切换账号时清理完整 HTTP 会话。
  Future<void> resetSession() => auth.cancelPendingLogin();

  Future<void> cancelPendingLogin() => auth.cancelPendingLogin();

  /// 释放底层连接。CookieJar 不会被写入磁盘。
  void close({bool force = false}) {
    dio.close(force: force);
  }
}

/// 让公共入口仍暴露教务异常类型，避免调用方需要知道内部目录结构。
typedef JiaowuError = JiaowuException;
