import 'dart:io';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../../domain/academic_data_source.dart';

typedef JiaowuClientFactory = JiaowuClient Function();

/// 本机直连教务数据源。
///
/// 一个数据源实例只拥有一个 [JiaowuClient]，因此登录、验证码、课程和
/// 成绩请求始终共享同一套 Dio、CookieJar 与 Session。Cookie 导出后只由
/// 上层身份级加密保险箱保存，数据源自身不直接写磁盘。
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
      _activeClient.getCreditRequirement();

  @override
  Future<void> resetSession() async {
    if (_closed) return;
    await _client?.resetSession();
  }

  Future<List<String>> exportCookies() async {
    final client = _activeClient;
    final cookies = await client.cookieJar.loadForRequest(
      Uri.parse(client.dio.options.baseUrl).resolve(JiaowuEndpoints.studentInfo));
    return cookies.map((cookie) => cookie.toString()).toList(growable: false);
  }

  Future<void> importCookies(List<String> values, String studentId) async {
    final client = _activeClient;
    final uri = Uri.parse(client.dio.options.baseUrl).resolve(JiaowuEndpoints.studentInfo);
    final cookies = values.map(Cookie.fromSetCookieValue).toList();
    for (final cookie in cookies) {
      final domain = cookie.domain?.replaceFirst(RegExp(r'^\.'), '');
      if (domain != null && domain.isNotEmpty && domain != uri.host) {
        throw const FormatException('本科会话 Cookie 来源不匹配');
      }
    }
    await client.resetSession();
    await client.cookieJar.saveFromResponse(uri, cookies);
    client.session.beginLogin(studentId);
  }

  /// 探活必须取得学校明确返回的学号，HTTP 200 或导入成功本身不是认证。
  Future<StudentProfile> probeSession() async {
    final client = _activeClient;
    try {
      final response = await client.dio.get<String>(JiaowuEndpoints.studentInfo,
        queryParameters: {'gnmkdm': 'N100801', 'layout': 'default', 'su': studentId},
        options: Options(responseType: ResponseType.plain, followRedirects: false));
      final body = response.data ?? '';
      if (response.statusCode == 901 || LoginPageDetector.isLoginPage(body)) {
        client.session.markExpired();
        throw const SessionExpiredException();
      }
      if (response.statusCode == 302) {
        final location = response.headers.value('location') ?? '';
        if (location.contains('login_slogin')) {
          client.session.markExpired();
          throw const SessionExpiredException();
        }
        throw const ParseException(message: '本科教务探活返回未知跳转');
      }
      if (response.statusCode != 200) {
          throw NetworkException(message: '学校暂时不可用',
              code: (response.statusCode ?? 0) >= 500 ? 'SCHOOL_UNAVAILABLE' : 'NETWORK_ERROR');
      }
      final profile = ProfileParser.parse(body);
      if (profile.studentId?.trim().isNotEmpty == true &&
          profile.studentId!.trim() != studentId?.trim()) {
        throw const ParseException(message: '本科教务会话身份不匹配');
      }
      client.session.markAuthenticated();
      return profile;
    } on DioException catch (error) {
      throw TransportErrorMapper.map(error, '本科教务探活');
    }
  }

  @override
  Future<void> restoreSession() async {
    // 本机直连没有服务端凭据，登录态只能由用户重新建立。
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client?.close(force: true);
    _client = null;
  }
}
