import 'package:flutter/foundation.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import 'diagnostic_dio_factory.dart';

/// 页面依赖的最小教务能力，便于用假实现验证 UI 状态和错误映射。
abstract interface class JiaowuGateway {
  SessionState get sessionState;
  Future<LoginResult> login({
    required String studentId,
    required String password,
  });
  Future<CaptchaChallenge> getCaptchaChallenge();
  Future<LoginResult> continueLoginWithCaptcha({required String code});
  Future<void> cancelPendingLogin();
  Future<StudentProfile> getProfile();
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  });
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  });
  Future<JiaowuNetworkProbeResult> diagnoseNetwork({bool insecureTls = false});
  void close();
}

/// 一个 Gateway 实例只持有一个 JiaowuClient，保证 Dio/CookieJar 会话连续。
final class JiaowuClientGateway implements JiaowuGateway {
  JiaowuClientGateway({JiaowuClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? (() => JiaowuClient());

  final JiaowuClient Function() _clientFactory;
  JiaowuClient? _client;

  JiaowuClient get _activeClient => _client ??= JiaowuClient();

  @override
  SessionState get sessionState =>
      _client?.session.state ?? SessionState.unauthenticated;

  @override
  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) async {
    _client?.close(force: true);
    _client = _clientFactory();
    return _activeClient.login(studentId: studentId, password: password);
  }

  @override
  Future<StudentProfile> getProfile() => _activeClient.getProfile();

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() =>
      _activeClient.getCaptchaChallenge();

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) =>
      _activeClient.continueLoginWithCaptcha(code: code);

  @override
  Future<void> cancelPendingLogin() => _activeClient.cancelPendingLogin();

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) => _activeClient.getCourses(year: year, semester: semester);

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) => _activeClient.getGrades(year: year, semester: semester);

  @override
  Future<JiaowuNetworkProbeResult> diagnoseNetwork({
    bool insecureTls = false,
  }) async {
    if (insecureTls && !kDebugMode) {
      throw StateError('insecure TLS 诊断只允许 Debug 构建');
    }
    final dio = createDiagnosticDio(insecureTls: insecureTls);
    try {
      return await JiaowuNetworkProbe(dio: dio).run();
    } finally {
      dio.close(force: true);
    }
  }

  @override
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}
