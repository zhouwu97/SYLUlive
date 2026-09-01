import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

/// 页面依赖的最小教务能力，便于用假实现验证 UI 状态和错误映射。
abstract interface class JiaowuGateway {
  SessionState get sessionState;
  Future<LoginResult> login({
    required String studentId,
    required String password,
  });
  Future<StudentProfile> getProfile();
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  });
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  });
  void close();
}

/// 一个 Gateway 实例只持有一个 JiaowuClient，保证 Dio/CookieJar 会话连续。
final class JiaowuClientGateway implements JiaowuGateway {
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
    _client = JiaowuClient();
    return _activeClient.login(studentId: studentId, password: password);
  }

  @override
  Future<StudentProfile> getProfile() => _activeClient.getProfile();

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
  void close() {
    _client?.close();
    _client = null;
  }
}
