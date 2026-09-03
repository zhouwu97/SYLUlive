import 'package:dio/dio.dart';

import '../auth/login_page_detector.dart';
import '../core/jiaowu_endpoints.dart';
import '../core/jiaowu_headers.dart';
import '../error/jiaowu_exception.dart';
import '../model/grade_detail.dart';
import '../network/transport_error_mapper.dart';
import '../parser/grade_detail_parser.dart';
import '../session/jiaowu_session.dart';
import '../session/session_state.dart';

/// 成绩详情接口：按课程查询成绩构成明细。
///
/// 严格迁移 Python 端 fetch_grade_detail 的四候选 endpoint 回退逻辑：
/// 1. cjcx_cxCjxqGjh.html
/// 2. cjcx_getXsjcxx.html
/// 3. cjcx_cxCjmx.html
/// 4. cjcx_cxXsKscjList.html
///
/// 只有找到 components 才停止；所有候选均合法但没有构成 → GradeDetailUnavailable。
final class GradeDetailApi {
  GradeDetailApi({
    required Dio dio,
    required JiaowuSession session,
  })  : _dio = dio,
        _session = session;

  final Dio _dio;
  final JiaowuSession _session;

  /// 查询单门课程的成绩构成。
  ///
  /// 参数：
  /// - [year]: 学年，如 "2025"
  /// - [semester]: 学期，3=第一学期，12=第二学期
  /// - [classId]: 教学班 ID (jxb_id)
  /// - [courseName]: 课程名称
  /// - [courseId]: 可选，课程号 (kch_id)
  /// - [studentGradeId]: 可选，学生成绩 ID (xh_id)
  /// - [timeout]: 每个候选 endpoint 的超时时间
  Future<GradeDetail> fetch({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _requireAuthenticated();

    final baseForm = <String, String>{
      'xnm': year,
      'xqm': semester.toString(),
      'jxb_id': classId,
      'jxbid': classId,
      'kcmc': courseName,
    };
    if (studentGradeId != null) {
      baseForm['xh_id'] = studentGradeId;
    }
    if (courseId != null) {
      baseForm['kch_id'] = courseId;
      baseForm['kch'] = courseId;
    }

    // 四候选 endpoint，按顺序尝试
    final candidates = [
      _Candidate(
        endpoint: 'cjcx_cxCjxqGjh.html',
        form: baseForm,
      ),
      _Candidate(
        endpoint: 'cjcx_getXsjcxx.html',
        form: baseForm,
      ),
      _Candidate(
        endpoint: 'cjcx_cxCjmx.html',
        form: baseForm,
      ),
      _Candidate(
        endpoint: 'cjcx_cxXsKscjList.html',
        form: {
          ...baseForm,
          'doType': 'query',
          'queryModel.showCount': '20',
        },
      ),
    ];

    var lastMessage = '暂未获取到成绩构成';

    for (final candidate in candidates) {
      try {
        final response = await _dio.post<String>(
          '${_gradeBaseUrl}/${candidate.endpoint}',
          queryParameters: {'gnmkdm': 'N305005'},
          data: candidate.form,
          options: Options(
            headers: _detailHeaders(),
            responseType: ResponseType.plain,
            followRedirects: false,
            connectTimeout: timeout,
            receiveTimeout: timeout,
            sendTimeout: timeout,
          ),
        );

        final status = response.statusCode ?? 0;
        final body = response.data ?? '';

        // 严格错误分类：SessionExpired
        if (status == 302 || status == 901) {
          _session.markExpired();
          throw const SessionExpiredException();
        }

        // 严格错误分类：RemoteSystemUnavailable
        if (status != 200) {
          lastMessage = '详情接口返回状态码 $status';
          continue;
        }

        // 严格错误分类：SessionExpired (HTML login page)
        final contentType = response.headers.value('content-type') ?? '';
        if (contentType.contains('text/html') &&
            LoginPageDetector.isLoginPage(body)) {
          _session.markExpired();
          throw const SessionExpiredException();
        }

        // 解析响应
        final parsed = GradeDetailParser.parse(body, courseName);
        if (parsed.components.isNotEmpty) {
          return parsed;
        }

        if (parsed.message != null) {
          lastMessage = parsed.message!;
        }
      } on DioException catch (error) {
        throw TransportErrorMapper.map(error, '成绩详情查询');
      } on SessionExpiredException {
        rethrow;
      } on JiaowuException {
        rethrow;
      } on Exception catch (error) {
        // 不能 fail-open：抛出 NetworkException
        throw NetworkException(
          message: '成绩详情查询失败: ${error.toString()}',
          code: 'GRADE_DETAIL_FETCH_ERROR',
        );
      }
    }

    // 所有候选均合法但没有构成 → GradeDetailUnavailable
    return GradeDetail(
      success: false,
      courseName: courseName,
      totalGrade: '',
      components: const [],
      message: lastMessage,
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

  Map<String, String> _detailHeaders() => {
        ...JiaowuHeaders.grade,
        'Referer':
            '$_baseUrl${JiaowuEndpoints.gradePage}?gnmkdm=N305005&layout=default',
        'Origin': _origin,
      };

  String get _baseUrl => _dio.options.baseUrl.replaceFirst(RegExp(r'/$'), '');

  String get _gradeBaseUrl =>
      _baseUrl.replaceFirst('/xtgl', '/jwglxt/cjcx');

  String get _origin {
    final uri = Uri.parse(_baseUrl);
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }
}

class _Candidate {
  _Candidate({
    required this.endpoint,
    required this.form,
  });

  final String endpoint;
  final Map<String, String> form;
}
