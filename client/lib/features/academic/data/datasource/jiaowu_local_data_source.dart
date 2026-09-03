import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../../domain/academic_data_source.dart';

typedef JiaowuClientFactory = JiaowuClient Function();

/// 本机直连教务数据源。
///
/// 一个数据源实例只拥有一个 [JiaowuClient]，因此登录、验证码、课程和
/// 成绩请求始终共享同一套 Dio、CookieJar 与 Session。凭据和 Cookie 仅存
/// 在内存中，应用退出后由客户端重新登录。
final class JiaowuLocalDataSource implements AcademicDataSource {
  JiaowuLocalDataSource({JiaowuClientFactory? clientFactory})
      : _clientFactory = clientFactory ?? JiaowuClient.new;

  final JiaowuClientFactory _clientFactory;
  JiaowuClient? _client;
  bool _closed = false;

  JiaowuClient get _activeClient {
    if (_closed) throw StateError('本地教务数据源已关闭');
    return _client ??= _clientFactory();
  }

  @override
  String get sourceName => '本机直连';

  @override
  SessionState get sessionState =>
      _client?.session.state ?? SessionState.unauthenticated;

  @override
  String? get studentId => _client?.session.studentId;

  @override
  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) {
    return _activeClient.login(studentId: studentId, password: password);
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() =>
      _activeClient.getCaptchaChallenge();

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) =>
      _activeClient.continueLoginWithCaptcha(code: code);

  @override
  Future<StudentProfile> getProfile() => _activeClient.getProfile();

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) {
    return _activeClient.getCourses(year: year, semester: semester);
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) {
    return _activeClient.getGrades(year: year, semester: semester);
  }

  @override
  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) {
    return _activeClient.getGradeDetail(
      year: year,
      semester: semester,
      classId: classId,
      courseName: courseName,
      courseId: courseId,
      studentGradeId: studentGradeId,
    );
  }

  @override
  Future<AcademicSituation> getAcademicSituation() =>
      _activeClient.getAcademicSituation();

  @override
  Future<CreditRequirement> getCreditRequirements() =>
      _activeClient.getCreditRequirements();

  @override
  Future<void> resetSession() async {
    if (_closed) return;
    await _client?.resetSession();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client?.close(force: true);
    _client = null;
  }
}
