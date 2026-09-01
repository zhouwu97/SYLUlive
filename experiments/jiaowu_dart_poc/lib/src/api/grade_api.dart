import 'package:dio/dio.dart';

import '../auth/login_page_detector.dart';
import '../core/jiaowu_endpoints.dart';
import '../core/jiaowu_headers.dart';
import '../core/jiaowu_request_validator.dart';
import '../error/jiaowu_exception.dart';
import '../model/grade_fetch_result.dart';
import '../model/raw_grade.dart';
import '../parser/grade_parser.dart';
import '../session/jiaowu_session.dart';
import '../session/session_state.dart';

/// 成绩接口：先 warmup 建立模块会话，再使用同一 CookieJar 分页查询。
final class GradeApi {
  GradeApi({required Dio dio, required JiaowuSession session})
      : _dio = dio,
        _session = session;

  static const pageSize = 500;
  static const defaultMaxPages = 20;

  final Dio _dio;
  final JiaowuSession _session;

  Future<GradeFetchResult> fetch({
    required String year,
    required int semester,
    Duration totalBudget = const Duration(seconds: 20),
    int maxPages = defaultMaxPages,
  }) async {
    JiaowuRequestValidator.validateAcademicRequest(
      year: year,
      semester: semester,
    );
    if (maxPages < 1) {
      throw ArgumentError.value(maxPages, 'maxPages', '必须大于 0');
    }
    _requireAuthenticated();

    final stopwatch = Stopwatch()..start();
    final warmupTimeout = _remainingTimeout(stopwatch, totalBudget);
    if (warmupTimeout == null) {
      throw const RequestTimeoutException(message: '成绩查询总超时预算耗尽');
    }
    await _warmup(timeout: warmupTimeout);

    final grades = <RawGrade>[];
    var page = 1;
    while (true) {
      final pageTimeout = _remainingTimeout(stopwatch, totalBudget);
      if (pageTimeout == null) {
        throw const RequestTimeoutException(message: '成绩分页查询总超时');
      }
      final payload = await _fetchPage(
        year: year,
        semester: semester,
        page: page,
        timeout: pageTimeout,
      );
      grades.addAll(payload.grades);
      if (payload.grades.length < pageSize) {
        return GradeFetchResult(grades: grades, pages: page);
      }
      if (page >= maxPages) {
        throw const NetworkException(
          message: '成绩分页超过安全上限',
          code: 'GRADE_PAGE_LIMIT',
        );
      }
      page++;
    }
  }

  void _requireAuthenticated() {
    if (_session.state == SessionState.expired) {
      throw const SessionExpiredException();
    }
    if (_session.state != SessionState.authenticated ||
        _session.studentId == null) {
      throw const UnauthenticatedException();
    }
  }

  Future<void> _warmup({required Duration timeout}) async {
    try {
      final response = await _dio.get<String>(
        JiaowuEndpoints.gradePage,
        queryParameters: {
          'gnmkdm': 'N305005',
          'layout': 'default',
        },
        options: Options(
          headers: _warmupHeaders(),
          responseType: ResponseType.plain,
          followRedirects: false,
          connectTimeout: timeout,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
      final status = response.statusCode ?? 0;
      final body = response.data ?? '';
      if (status == 901 ||
          status == 302 ||
          LoginPageDetector.isLoginPage(body)) {
        _session.markExpired();
        throw const SessionExpiredException();
      }
      if (status != 200) {
        throw NetworkException(
          message: '成绩模块初始化失败，状态码 $status',
          code: 'GRADE_WARMUP_HTTP',
        );
      }
    } on DioException catch (error) {
      throw _mapTransportError(error, '成绩模块初始化');
    }
  }

  Future<ParsedGradePayload> _fetchPage({
    required String year,
    required int semester,
    required int page,
    required Duration timeout,
  }) async {
    try {
      final response = await _dio.post<String>(
        JiaowuEndpoints.gradeList,
        queryParameters: {
          'doType': 'query',
          'gnmkdm': 'N305005',
        },
        data: {
          'xnm': year,
          'xqm': semester.toString(),
          'queryModel.showCount': pageSize.toString(),
          'queryModel.currentPage': page.toString(),
        },
        options: Options(
          headers: _gradeHeaders(),
          responseType: ResponseType.plain,
          followRedirects: false,
          connectTimeout: timeout,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
      final status = response.statusCode ?? 0;
      final body = response.data ?? '';
      if (status == 901 ||
          status == 302 ||
          LoginPageDetector.isLoginPage(body)) {
        _session.markExpired();
        throw const SessionExpiredException();
      }
      if (status != 200) {
        throw NetworkException(
          message: '成绩接口返回状态码 $status',
          code: 'GRADE_HTTP_ERROR',
        );
      }
      final contentType = response.headers.value('content-type') ?? '';
      if (!contentType.toLowerCase().contains('application/json')) {
        throw const RemoteMaintenanceException(
          message: '成绩接口返回非 JSON，教务系统可能正在维护',
        );
      }
      return GradeParser.parse(body);
    } on DioException catch (error) {
      throw _mapTransportError(error, '成绩分页查询');
    }
  }

  Map<String, String> _warmupHeaders() => {
        ...JiaowuHeaders.gradeWarmup,
        'Referer': _baseUrl + JiaowuEndpoints.initMenu,
      };

  Map<String, String> _gradeHeaders() => {
        ...JiaowuHeaders.grade,
        'Referer':
            '$_baseUrl${JiaowuEndpoints.gradePage}?gnmkdm=N305005&layout=default',
        'Origin': _origin,
      };

  String get _baseUrl => _dio.options.baseUrl.replaceFirst(RegExp(r'/$'), '');

  String get _origin {
    final uri = Uri.parse(_baseUrl);
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }

  Duration? _remainingTimeout(Stopwatch stopwatch, Duration budget) {
    final remaining = budget - stopwatch.elapsed;
    if (remaining <= Duration.zero) return null;
    final configured =
        _dio.options.receiveTimeout ?? const Duration(seconds: 8);
    return configured < remaining ? configured : remaining;
  }

  static JiaowuException _mapTransportError(
    DioException error,
    String stage,
  ) {
    final isTimeout = error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout;
    if (isTimeout) {
      return RequestTimeoutException(message: '$stage超时');
    }
    return NetworkException(message: '$stage失败', cause: error);
  }
}
