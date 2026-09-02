import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../../domain/academic_data_source.dart';

/// 旧服务端代理数据源。
///
/// 这是迁移期间的兼容实现：它只使用 App JWT 所在的 Dio，不接触本机直连
/// 数据源的 CookieJar。新功能默认使用 [JiaowuLocalDataSource]；生产 App
/// 通过 [networkEnabled] 关闭本类的网络出口，测试和独立旧版构建仍可显式启用。
final class LegacyServerDataSource implements AcademicDataSource {
  LegacyServerDataSource(this._dio, {this.networkEnabled = false});

  final Dio _dio;
  final bool networkEnabled;
  SessionState _sessionState = SessionState.unauthenticated;
  String? _studentId;
  bool _closed = false;

  @override
  String get sourceName => '服务端兼容代理';

  @override
  SessionState get sessionState => _sessionState;

  @override
  String? get studentId => _studentId;

  @override
  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) async {
    _ensureOpen();
    _ensureNetworkEnabled();
    try {
      final response = await _dio.post(
        '/edu/bind',
        data: {
          'student_id': studentId,
          'password': password,
          'edu_data_consent_accepted': true,
        },
      );
      final data = _asMap(response.data);
      if (response.statusCode == 200 && data != null) {
        final user = _asMap(data['user']) ?? data;
        final resolvedStudentId = _text(
          user,
          const ['edu_student_id', 'student_id'],
        );
        if (resolvedStudentId.isNotEmpty &&
            (user['edu_authorized'] == true || data['success'] == true)) {
          _studentId = resolvedStudentId;
          _sessionState = SessionState.authenticated;
          return LoginSuccess(
            studentId: resolvedStudentId,
            cookieNames: const {'legacy-server'},
          );
        }
      }

      final code = _text(data, const ['code', 'upstream_code']).toUpperCase();
      if (_isCredentialFailure(code, data)) {
        return InvalidCredentials(message: _message(data, '教务账号或密码错误'));
      }
      return LoginPageChanged(
        message: _message(data, '旧服务端返回了无法识别的教务登录结果'),
      );
    } on DioException catch (error) {
      return NetworkUnavailable(
        message: _networkMessage(error),
        cause: NetworkException(
          message: _networkMessage(error),
          code: 'LEGACY_NETWORK_ERROR',
        ),
      );
    }
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() async {
    _ensureNetworkEnabled();
    throw const LoginPageChangedException(
      message: '旧服务端代理不提供验证码图片，请使用本机直连',
    );
  }

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) async {
    _ensureNetworkEnabled();
    return const LoginPageChanged(
      message: '旧服务端代理不支持本地验证码流程，请重新选择本机直连',
    );
  }

  @override
  Future<StudentProfile> getProfile() async {
    _ensureAuthenticated();
    _ensureNetworkEnabled();
    try {
      final response = await _dio.get('/edu/status');
      final data = _requireSuccessfulMap(response, '获取学生信息');
      return StudentProfile(
        name: _text(data, const ['name']),
        grade: _text(data, const ['edu_grade', 'grade']),
        college: _text(data, const ['edu_college', 'college']),
        major: _text(data, const ['edu_major', 'major']),
      );
    } on DioException catch (error) {
      throw _networkException(error, '获取学生信息');
    }
  }

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) async {
    _ensureAuthenticated();
    _ensureNetworkEnabled();
    try {
      final response = await _dio.post(
        '/edu/courses',
        data: {'year': year, 'semester': semester},
      );
      final data = _requireSuccessfulMap(response, '获取课表');
      final rawCourses = data['courses'];
      if (rawCourses is! List) {
        throw const ProtocolChangedException(message: '旧课表响应缺少 courses');
      }
      final courses = <RawCourse>[];
      for (final raw in rawCourses) {
        final map = _asMap(raw);
        if (map == null) {
          throw const ProtocolChangedException(message: '旧课表记录结构异常');
        }
        courses.add(_courseFromMap(map));
      }
      return CourseFetchResult(
        courses: courses,
        source: CourseSource.mobile,
      );
    } on DioException catch (error) {
      throw _networkException(error, '获取课表');
    }
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) async {
    _ensureAuthenticated();
    _ensureNetworkEnabled();
    try {
      final response = await _dio.post(
        '/edu/grades',
        data: {'year': year, 'semester': semester},
      );
      final data = _requireSuccessfulMap(response, '获取成绩');
      final rawGrades = data['grades'];
      if (rawGrades is! List) {
        throw const ProtocolChangedException(message: '旧成绩响应缺少 grades');
      }
      final grades = <RawGrade>[];
      for (final raw in rawGrades) {
        final map = _asMap(raw);
        if (map == null) {
          throw const ProtocolChangedException(message: '旧成绩记录结构异常');
        }
        grades.add(RawGrade(raw: Map<String, Object?>.from(map)));
      }
      return GradeFetchResult(grades: grades, pages: 1);
    } on DioException catch (error) {
      throw _networkException(error, '获取成绩');
    }
  }

  @override
  Future<void> resetSession() async {
    if (_closed) return;
    _studentId = null;
    _sessionState = SessionState.unauthenticated;
    if (!networkEnabled) return;
    // 旧代理的会话由服务端管理；退出失败不能阻止本地账号切换清理。
    try {
      await _dio.post('/edu/session/logout');
    } on DioException {
      // 不记录响应体、Cookie 或请求参数。
    }
  }

  @override
  void close() {
    _closed = true;
  }

  Map<String, dynamic> _requireSuccessfulMap(
    Response<dynamic> response,
    String operation,
  ) {
    final data = _asMap(response.data);
    final code = _text(data, const ['code', 'upstream_code']).toUpperCase();
    if (code.contains('SESSION_EXPIRED') ||
        code == 'EDU_SESSION_EXPIRED' ||
        response.statusCode == 409) {
      _sessionState = SessionState.expired;
      throw const SessionExpiredException();
    }
    if (response.statusCode != 200 || data == null) {
      throw NetworkException(
        message: _message(data, '$operation失败'),
        code: 'LEGACY_HTTP_${response.statusCode ?? 0}',
      );
    }
    if (data['success'] == false) {
      throw NetworkException(
        message: _message(data, '$operation失败'),
        code: code.isEmpty ? 'LEGACY_OPERATION_FAILED' : code,
      );
    }
    return data;
  }

  RawCourse _courseFromMap(Map<String, dynamic> map) {
    final sectionText = _text(map, const [
      'section',
      'jc',
      'section_text',
    ]);
    final sectionNumbers = _numbersInText(sectionText);
    final start = _firstInt(map, const [
          'start_section',
          'startSection',
          'time',
          'jc_start',
        ]) ??
        (sectionNumbers.isNotEmpty ? sectionNumbers.first : null);
    final end = _firstInt(map, const [
          'end_section',
          'endSection',
          'jc_end',
        ]) ??
        (sectionNumbers.length > 1 ? sectionNumbers.last : start);
    if (start == null || start <= 0) {
      throw const ProtocolChangedException(message: '旧课表记录缺少开始节次');
    }
    if (end == null || end < start) {
      throw const ProtocolChangedException(message: '旧课表记录缺少有效结束节次');
    }
    final expression = _text(map, const [
      'weekExpression',
      'week_expression',
      'weeks_text',
      'zcd',
    ]);
    final weekDay = _firstInt(map, const [
      'weekday',
      'week_day',
      'dayOfWeek',
      'day_of_week',
      'xqj',
    ]);
    if (weekDay == null || weekDay < 1 || weekDay > 7) {
      throw const ProtocolChangedException(message: '旧课表记录缺少有效星期');
    }
    return RawCourse(
      name: _text(map, const ['name', 'course_name', 'courseName', 'kcmc']),
      teacher:
          _text(map, const ['teacher', 'teacher_name', 'teacherName', 'jsxm']),
      location: _text(map, const ['location', 'classroom', 'room', 'jxdd']),
      section: sectionText.isNotEmpty ? sectionText : '$start-$end节',
      weekDay: weekDay.toString(),
      weekExpression: expression.isNotEmpty
          ? expression
          : _weeksToExpression(map['weeks'] ?? map['week_list']),
    );
  }

  void _ensureOpen() {
    if (_closed) throw StateError('旧教务数据源已关闭');
  }

  void _ensureNetworkEnabled() {
    if (!networkEnabled) {
      throw const NetworkException(
        message: '教务服务器接口已阻断，请使用本机直连教务',
        code: 'LEGACY_SERVER_BLOCKED',
      );
    }
  }

  void _ensureAuthenticated() {
    _ensureOpen();
    if (_sessionState == SessionState.expired) {
      throw const SessionExpiredException();
    }
    if (_sessionState != SessionState.authenticated || _studentId == null) {
      throw const UnauthenticatedException();
    }
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value);
  }

  static String _text(
    Map<String, dynamic>? map,
    List<String> keys, {
    String fallback = '',
  }) {
    if (map == null) return fallback;
    for (final key in keys) {
      final value = map[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }
    return fallback;
  }

  static int? _firstInt(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value?.toString().trim() ?? '');
      if (parsed != null) return parsed;
      final match = RegExp(r'\d+').firstMatch(value?.toString() ?? '');
      final fromText = int.tryParse(match?.group(0) ?? '');
      if (fromText != null) return fromText;
    }
    return null;
  }

  static List<int> _numbersInText(String value) {
    return RegExp(r'\d+')
        .allMatches(value)
        .map((match) => int.parse(match.group(0)!))
        .toList(growable: false);
  }

  static String _weeksToExpression(Object? value) {
    if (value is! List || value.isEmpty) return '';
    return '${value.join(',')}周';
  }

  static bool _isCredentialFailure(
    String code,
    Map<String, dynamic>? data,
  ) {
    if (code.contains('INVALID_CREDENTIAL') ||
        code.contains('BINDING_REJECTED')) {
      return true;
    }
    final message = _message(data, '').toLowerCase();
    return message.contains('密码错误') || message.contains('账号或密码');
  }

  static String _message(Map<String, dynamic>? data, String fallback) {
    final value = data?['error'] ?? data?['message'] ?? data?['detail'];
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static String _networkMessage(DioException error) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return '旧教务代理请求超时';
    }
    return '旧教务代理暂时不可用，请稍后重试';
  }

  static NetworkException _networkException(
    DioException error,
    String operation,
  ) {
    return NetworkException(
      message: '${_networkMessage(error)}（$operation）',
      code: 'LEGACY_NETWORK_ERROR',
    );
  }
}
