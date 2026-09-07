import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../../domain/academic_data_source.dart';

/// 旧服务端代理数据源。
///
/// 服务端教务数据源只使用 App JWT 所在的 Dio，不接触本机直连数据源的
/// CookieJar。教务密码和 Cookie 由服务端加密保存并负责自动恢复。
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

  /// 读取服务端已有绑定，并在需要时恢复教务会话。
  Future<void> restore() async {
    try {
      await _restore();
    } on DioException catch (error) {
      throw _networkException(error, '恢复教务绑定');
    }
  }

  Future<void> _restore() async {
    _ensureOpen();
    _ensureNetworkEnabled();
    final response = await _dio.get('/edu/status');
    final data = _requireSuccessfulMap(response, '获取教务绑定状态');
    final authorized =
        data['edu_authorized'] == true || data['edu_bound'] == true;
    if (!authorized) {
      _studentId = null;
      _sessionState = SessionState.unauthenticated;
      return;
    }
    _studentId = _text(data, const ['edu_student_id', 'student_id']);
    final state = _text(data, const ['edu_session_state'], fallback: 'active');
    if (state == 'active') {
      _sessionState = SessionState.authenticated;
      return;
    }
    // 已确认过期，恢复请求失败时不能继续向页面报告在线。
    _sessionState = SessionState.expired;
    final resumed = await _dio.post('/edu/session/resume');
    final resumedData = _requireSuccessfulMap(resumed, '恢复教务会话');
    if (resumedData['edu_authorized'] != true ||
        resumedData['edu_session_state'] != 'active') {
      _sessionState = SessionState.expired;
      throw const SessionExpiredException();
    }
    _studentId = _text(resumedData, const ['edu_student_id', 'student_id'],
        fallback: _studentId ?? '');
    _sessionState = SessionState.authenticated;
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
  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) async {
    _ensureAuthenticated();
    _ensureNetworkEnabled();
    try {
      final response = await _dio.post(
        '/edu/grades/detail',
        data: {
          'year': year,
          'semester': semester,
          'class_id': classId,
          'course_name': courseName,
          if (courseId != null && courseId.isNotEmpty) 'course_id': courseId,
          if (studentGradeId != null && studentGradeId.isNotEmpty)
            'student_grade_id': studentGradeId,
        },
      );
      final data = _requireSuccessfulMap(response, '获取成绩详情');
      final rawComponents = data['components'];
      if (rawComponents is! List) {
        throw const ProtocolChangedException(message: '成绩详情响应缺少 components');
      }
      final components = <GradeComponent>[];
      for (final raw in rawComponents) {
        final component = _asMap(raw);
        if (component == null) {
          throw const ProtocolChangedException(message: '成绩详情分项结构异常');
        }
        components.add(
          GradeComponent(
            name: _text(component, const ['name']),
            weight: _nullableText(component, const ['weight']),
            score: _text(component, const ['score']),
          ),
        );
      }
      return GradeDetail(
        success: data['success'] == true,
        courseName: _text(data, const ['course_name'], fallback: courseName),
        totalGrade: _text(data, const ['total_grade']),
        components: components,
        message: _nullableText(data, const ['message']),
      );
    } on DioException catch (error) {
      throw _networkException(error, '获取成绩详情');
    }
  }

  @override
  Future<AcademicSituation> getAcademicSituation() async {
    _ensureAuthenticated();
    _ensureNetworkEnabled();
    try {
      final response = await _dio.post('/edu/academic-situation');
      final data = _requireSuccessfulMap(response, '获取学业情况');
      final rawCourses = data['courses'];
      if (rawCourses is! List) {
        throw const ProtocolChangedException(message: '学业情况响应缺少 courses');
      }
      final courses = <AcademicCourse>[];
      for (final raw in rawCourses) {
        final course = _asMap(raw);
        if (course == null) {
          throw const ProtocolChangedException(message: '学业情况课程结构异常');
        }
        courses.add(_academicCourseFromMap(course));
      }
      return AcademicSituation(
        success: data['success'] == true,
        allGpa: _doubleValue(data['all_gpa']),
        degreeGpa: _doubleValue(data['degree_gpa']),
        totalCourses: _firstInt(data, const ['total_courses']),
        passedCourses: _firstInt(data, const ['passed_courses']),
        failedCourses: _firstInt(data, const ['failed_courses']),
        notStartedCourses: _firstInt(data, const ['not_started_courses']),
        inProgressCourses: _firstInt(data, const ['in_progress_courses']),
        degreeTotalCourses: _firstInt(data, const ['degree_total_courses']),
        degreePassedCourses: _firstInt(data, const ['degree_passed_courses']),
        degreeFailedCourses: _firstInt(data, const ['degree_failed_courses']),
        degreeNotStartedCourses:
            _firstInt(data, const ['degree_not_started_courses']),
        degreeInProgressCourses:
            _firstInt(data, const ['degree_in_progress_courses']),
        courses: courses,
        coursesStatus:
            _text(data, const ['courses_status'], fallback: 'unknown'),
        message: _nullableText(data, const ['message']),
        errorCode: _nullableText(data, const ['error_code']),
      );
    } on DioException catch (error) {
      throw _networkException(error, '获取学业情况');
    }
  }

  @override
  Future<CreditRequirement> getCreditRequirements() async {
    _ensureAuthenticated();
    _ensureNetworkEnabled();
    try {
      final response = await _dio.post('/edu/credit-requirements');
      final data = _requireSuccessfulMap(response, '获取学分要求');
      final rawModules = data['modules'];
      final rawImprovementCourses = data['improvement_courses'];
      if (rawModules is! List || rawImprovementCourses is! List) {
        throw const ProtocolChangedException(message: '学分要求响应缺少课程模块');
      }
      final modules = <CreditModule>[];
      for (final raw in rawModules) {
        final module = _asMap(raw);
        if (module == null) {
          throw const ProtocolChangedException(message: '学分要求模块结构异常');
        }
        modules.add(_creditModuleFromMap(module));
      }
      final improvementCourses = <ImprovementCourse>[];
      for (final raw in rawImprovementCourses) {
        final course = _asMap(raw);
        if (course == null) {
          throw const ProtocolChangedException(message: '提高课程结构异常');
        }
        improvementCourses.add(
          ImprovementCourse(
            courseId: _text(course, const ['course_code', 'course_id']),
            courseName: _text(course, const ['course_name']),
            credits: _doubleValue(course['credits']) ?? 0,
            grade: _text(course, const ['grade']),
            status: _text(course, const ['raw_status', 'status']),
          ),
        );
      }
      return CreditRequirement(
        success: data['success'] == true,
        status: _text(data, const ['status'], fallback: 'unknown'),
        modules: modules,
        improvementCourses: improvementCourses,
        message: _nullableText(data, const ['message']),
        errorCode: _nullableText(data, const ['error_code']),
      );
    } on DioException catch (error) {
      throw _networkException(error, '获取学分要求');
    }
  }

  @override
  Future<void> resetSession() async {
    if (_closed) return;
    _studentId = null;
    _sessionState = SessionState.unauthenticated;
    if (!networkEnabled) return;
    // App 账号退出不撤销教务授权，服务端凭据继续保留供下次登录恢复。
  }

  @override
  Future<void> restoreSession() async {
    await restore();
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

  static String? _nullableText(Map<String, dynamic> map, List<String> keys) {
    final value = _text(map, keys);
    return value.isEmpty ? null : value;
  }

  static double? _doubleValue(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().trim() ?? '');
  }

  static bool _boolValue(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = value?.toString().trim().toLowerCase();
    return text == 'true' || text == '1' || text == '是';
  }

  static AcademicCourse _academicCourseFromMap(Map<String, dynamic> map) {
    return AcademicCourse(
      courseName: _text(map, const ['course_name']),
      courseId: _text(map, const ['course_code', 'course_id']),
      credits: _doubleValue(map['credits']) ?? 0,
      status: _text(map, const ['study_status', 'status']),
      effectiveGrade: _text(map, const ['effective_grade']),
      effectivePassed: _boolValue(map['effective_passed']),
      isDegree: _boolValue(map['is_degree']),
      hasRetake: _boolValue(map['has_retake']),
      maxGrade: _nullableText(map, const ['max_grade']),
      gpa: _doubleValue(map['gpa']),
      courseCategory: _nullableText(map, const ['course_category']),
      courseNature: _nullableText(map, const ['course_nature']),
    );
  }

  static CreditModule _creditModuleFromMap(Map<String, dynamic> map) {
    final rawCourses = map['courses'];
    if (rawCourses is! List) {
      throw const ProtocolChangedException(message: '学分要求模块缺少课程列表');
    }
    final courses = <ModuleCourse>[];
    for (final raw in rawCourses) {
      final course = _asMap(raw);
      if (course == null) {
        throw const ProtocolChangedException(message: '学分要求课程结构异常');
      }
      courses.add(
        ModuleCourse(
          courseId: _text(course, const ['course_code', 'course_id']),
          courseName: _text(course, const ['course_name']),
          credits: _doubleValue(course['credits']) ?? 0,
          grade: _text(course, const ['grade']),
          status: _text(course, const ['raw_status', 'status']),
          suggestedYear: _nullableText(course, const ['suggested_year']),
          suggestedSemester:
              _nullableText(course, const ['suggested_semester']),
          actualYear: _nullableText(course, const ['actual_year']),
          actualSemester: _nullableText(course, const ['actual_semester']),
        ),
      );
    }
    return CreditModule(
      name: _text(map, const ['name']),
      requiredCredits: _doubleValue(map['required_credits']),
      earnedCredits: _doubleValue(map['earned_credits']) ?? 0,
      status: _text(map, const ['status'], fallback: 'unknown'),
      courses: courses,
      requiredCourseCount: _firstInt(map, const ['required_course_count']),
    );
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
