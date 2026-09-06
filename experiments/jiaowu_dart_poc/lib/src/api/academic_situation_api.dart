import 'package:dio/dio.dart';

import '../auth/login_page_detector.dart';
import '../error/jiaowu_exception.dart';
import '../model/academic_situation.dart';
import '../parser/academic_situation_parser.dart';
import '../session/jiaowu_session.dart';
import '../session/session_state.dart';

/// 学业情况 API。
///
/// 对应教务系统 /xsxy/xsxyqk_cxXsxyqkIndex.html 端点。
final class AcademicSituationApi {
  const AcademicSituationApi({
    required Dio dio,
    required JiaowuSession session,
  })  : _dio = dio,
        _session = session;

  final Dio _dio;
  final JiaowuSession _session;

  /// 获取学业情况。
  Future<AcademicSituation> fetch() async {
    if (_session.state != SessionState.authenticated) {
      throw const UnauthenticatedException();
    }

    try {
      final response = await _dio.get<String>(
        '/xsxy/xsxyqk_cxXsxyqkIndex.html',
        queryParameters: {
          'gnmkdm': 'N105515',
          'layout': 'default',
        },
        options: Options(
          headers: {
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Referer': 'https://jxw.sylu.edu.cn/xtgl/index_initMenu.html',
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final body = response.data;
      if (body == null || body.isEmpty) {
        throw const ParseException(
          message: '学业情况响应为空',
          code: 'EMPTY_RESPONSE',
        );
      }

      // 检查会话过期
      if (response.statusCode == 302 ||
          response.statusCode == 901 ||
          LoginPageDetector.isLoginPage(body)) {
        _session.markExpired();
        throw const SessionExpiredException();
      }

      if (response.statusCode != 200) {
        throw NetworkException(
          message: '学业情况接口返回状态码 ${response.statusCode}',
          code: 'REMOTE_SYSTEM_UNAVAILABLE',
        );
      }

      final situation = AcademicSituationParser.parse(body);
      if (!situation.success) {
        throw ParseException(
          message: situation.message ?? '学业情况解析失败',
          code: 'ACADEMIC_SITUATION_PARSE_ERROR',
        );
      }

      return situation;
    } on DioException catch (e) {
      throw NetworkException(
        message: '学业情况查询失败: ${e.message}',
        cause: e,
      );
    }
  }
}

