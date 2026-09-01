import 'package:dio/dio.dart';

import '../auth/login_page_detector.dart';
import '../core/jiaowu_endpoints.dart';
import '../core/jiaowu_headers.dart';
import '../core/jiaowu_request_validator.dart';
import '../error/jiaowu_exception.dart';
import '../model/course_fetch_result.dart';
import '../parser/course_parser.dart';
import '../session/jiaowu_session.dart';
import '../session/session_state.dart';

/// 课表接口：Desktop 优先，只有可恢复的解析/网络失败才回退 Mobile。
final class CourseApi {
  CourseApi({required Dio dio, required JiaowuSession session})
      : _dio = dio,
        _session = session;

  final Dio _dio;
  final JiaowuSession _session;

  Future<CourseFetchResult> fetch({
    required String year,
    required int semester,
    Duration totalBudget = const Duration(seconds: 12),
  }) async {
    JiaowuRequestValidator.validateAcademicRequest(
      year: year,
      semester: semester,
    );
    _requireAuthenticated();
    final stopwatch = Stopwatch()..start();
    final failures = <String>[];
    var sawValidEmpty = false;

    final desktopTimeout = _remainingTimeout(stopwatch, totalBudget);
    if (desktopTimeout != null) {
      try {
        final outcome = await _fetchEndpoint(
          endpoint: JiaowuEndpoints.courseDesktop,
          source: 'DESKTOP',
          form: {
            'xnm': year,
            'xqm': semester.toString(),
            'kblx': '1',
          },
          headers: _desktopHeaders(),
          timeout: desktopTimeout,
        );
        if (outcome.payload != null && !outcome.payload!.validEmpty) {
          return CourseFetchResult(
            courses: outcome.payload!.courses,
            source: CourseSource.desktop,
          );
        }
        if (outcome.payload?.validEmpty == true) {
          sawValidEmpty = true;
        } else if (outcome.failure != null) {
          failures.add(outcome.failure!);
        }
      } on SessionExpiredException {
        rethrow;
      } catch (error) {
        failures.add(_failure('DESKTOP', error));
      }
    } else {
      failures.add('DESKTOP:budget_exhausted');
    }

    final mobileTimeout = _remainingTimeout(stopwatch, totalBudget);
    if (mobileTimeout != null) {
      try {
        final outcome = await _fetchEndpoint(
          endpoint: JiaowuEndpoints.courseMobile,
          source: 'MOBILE',
          form: {
            'xnm': year,
            'zs': '1',
            'doType': 'app',
            'xqm': semester.toString(),
            'kblx': '1',
          },
          headers: _mobileHeaders(),
          timeout: mobileTimeout,
        );
        if (outcome.payload != null && !outcome.payload!.validEmpty) {
          return CourseFetchResult(
            courses: outcome.payload!.courses,
            source: CourseSource.mobile,
          );
        }
        if (outcome.payload?.validEmpty == true) {
          sawValidEmpty = true;
        } else if (outcome.failure != null) {
          failures.add(outcome.failure!);
        }
      } on SessionExpiredException {
        rethrow;
      } catch (error) {
        failures.add(_failure('MOBILE', error));
      }
    } else {
      failures.add('MOBILE:budget_exhausted');
    }

    if (sawValidEmpty) {
      throw const CourseNotOpenException();
    }
    final detail = failures.isEmpty ? 'no_response' : failures.join(',');
    throw NetworkException(
      message: '教务课表接口无法解析($detail)',
      code: 'COURSE_FETCH_UNPARSABLE',
    );
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

  Future<_EndpointOutcome> _fetchEndpoint({
    required String endpoint,
    required String source,
    required Map<String, String> form,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    try {
      final response = await _dio.post<String>(
        endpoint,
        queryParameters: {'gnmkdm': 'N2154'},
        data: form,
        options: Options(
          headers: headers,
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
        return _EndpointOutcome.failure('$source:http_$status');
      }
      try {
        return _EndpointOutcome.success(CourseParser.parse(body));
      } on JiaowuException catch (error) {
        return _EndpointOutcome.failure('$source:${error.code}');
      }
    } on DioException catch (error) {
      throw _mapTransportError(error, source);
    }
  }

  Map<String, String> _desktopHeaders() => {
        ...JiaowuHeaders.course,
        'Referer': _baseUrl + '${JiaowuEndpoints.courseDesktop}?gnmkdm=N2154',
        'Origin': _origin,
      };

  Map<String, String> _mobileHeaders() => {
        ...JiaowuHeaders.course,
        'Referer': _baseUrl + '${JiaowuEndpoints.courseDesktop}?gnmkdm=N2154',
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
    String source,
  ) {
    final isTimeout = error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout;
    if (isTimeout) {
      return RequestTimeoutException(message: '$source课表请求超时');
    }
    return NetworkException(message: '$source课表请求失败', cause: error);
  }

  static String _failure(String source, Object error) {
    if (error is JiaowuException) return '$source:${error.code}';
    return '$source:${error.runtimeType}';
  }
}

final class _EndpointOutcome {
  const _EndpointOutcome._({this.payload, this.failure});

  final ParsedCoursePayload? payload;
  final String? failure;

  factory _EndpointOutcome.success(ParsedCoursePayload payload) =>
      _EndpointOutcome._(payload: payload);

  factory _EndpointOutcome.failure(String failure) =>
      _EndpointOutcome._(failure: failure);
}
