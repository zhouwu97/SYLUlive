import 'package:dio/dio.dart';

import '../auth/login_page_detector.dart';
import '../error/jiaowu_exception.dart';
import '../model/credit_requirement.dart';
import '../parser/credit_requirement_parser.dart';
import '../session/jiaowu_session.dart';
import '../session/session_state.dart';

/// 学分要求 API。
///
/// 对应教务系统 /xjyj/xjyj_cxXjyjIndex.html 端点。
final class CreditRequirementApi {
  const CreditRequirementApi({
    required Dio dio,
    required JiaowuSession session,
  })  : _dio = dio,
        _session = session;

  final Dio _dio;
  final JiaowuSession _session;

  /// 获取学分要求。
  Future<CreditRequirement> fetch() async {
    if (_session.state != SessionState.authenticated) {
      throw const UnauthenticatedException();
    }

    try {
      // 第一步：获取入口页面
      final entryResponse = await _dio.get<String>(
        '/xjyj/xjyj_cxXjyjIndex.html',
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

      final entryBody = entryResponse.data;
      if (entryBody == null || entryBody.isEmpty) {
        throw const ParseException(
          message: '学分要求响应为空',
          code: 'EMPTY_RESPONSE',
        );
      }

      // 检查会话过期
      if (entryResponse.statusCode == 302 ||
          entryResponse.statusCode == 901 ||
          LoginPageDetector.isLoginPage(entryBody)) {
        _session.markExpired();
        throw const SessionExpiredException();
      }

      if (entryResponse.statusCode != 200) {
        throw NetworkException(
          message: '学分要求接口返回状态码 ${entryResponse.statusCode}',
          code: 'REMOTE_SYSTEM_UNAVAILABLE',
        );
      }

      // 尝试从入口页解析查询参数
      final queryParams = _extractQueryParams(entryBody);

      // 如果没有查询参数或入口页已包含完整数据，直接解析
      if (queryParams.isEmpty || _looksComplete(entryBody)) {
        final requirement = CreditRequirementParser.parse(entryBody);
        if (!requirement.success) {
          throw ParseException(
            message: requirement.message ?? '学分要求解析失败',
            code: 'CREDIT_REQUIREMENT_PARSE_ERROR',
          );
        }
        return requirement;
      }

      // 第二步：使用查询参数获取详细数据
      final detailResponse = await _dio.post<String>(
        '/xjyj/xjyj_cxXjyjjdlb.html',
        queryParameters: {
          'gnmkdm': 'N105515',
        },
        data: queryParams,
        options: Options(
          headers: {
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': 'https://jxw.sylu.edu.cn/xjyj/xjyj_cxXjyjIndex.html',
          },
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final detailBody = detailResponse.data;
      if (detailBody == null || detailBody.isEmpty) {
        throw const ParseException(
          message: '学分要求详细响应为空',
          code: 'EMPTY_RESPONSE',
        );
      }

      // 检查会话过期
      if (detailResponse.statusCode == 302 ||
          detailResponse.statusCode == 901 ||
          LoginPageDetector.isLoginPage(detailBody)) {
        _session.markExpired();
        throw const SessionExpiredException();
      }

      if (detailResponse.statusCode != 200) {
        throw NetworkException(
          message: '学分要求详细接口返回状态码 ${detailResponse.statusCode}',
          code: 'REMOTE_SYSTEM_UNAVAILABLE',
        );
      }

      final requirement = CreditRequirementParser.parse(detailBody);
      if (!requirement.success) {
        throw ParseException(
          message: requirement.message ?? '学分要求解析失败',
          code: 'CREDIT_REQUIREMENT_PARSE_ERROR',
        );
      }

      return requirement;
    } on DioException catch (e) {
      throw NetworkException(
        message: '学分要求查询失败: ${e.message}',
        cause: e,
      );
    }
  }

  /// 从入口页 HTML 提取查询参数。
  Map<String, String> _extractQueryParams(String html) {
    final params = <String, String>{};

    // 提取隐藏字段
    final inputPattern = RegExp(
      r'<input[^>]*type=["' "'" r']hidden["' "'" r'][^>]*name=["' "'" r']([^"' "'" r']+)["' "'" r'][^>]*value=["' "'" r']([^"' "'" r']*)["' "'" r']',
      caseSensitive: false,
    );

    for (final match in inputPattern.allMatches(html)) {
      final name = match.group(1);
      final value = match.group(2);
      if (name != null && value != null) {
        params[name] = value;
      }
    }

    // 也尝试另一种顺序：value 在前
    final inputPattern2 = RegExp(
      r'<input[^>]*type=["' "'" r']hidden["' "'" r'][^>]*value=["' "'" r']([^"' "'" r']*)["' "'" r'][^>]*name=["' "'" r']([^"' "'" r']+)["' "'" r']',
      caseSensitive: false,
    );

    for (final match in inputPattern2.allMatches(html)) {
      final value = match.group(1);
      final name = match.group(2);
      if (name != null && value != null && !params.containsKey(name)) {
        params[name] = value;
      }
    }

    return params;
  }

  /// 检查页面是否已包含完整数据。
  bool _looksComplete(String html) {
    // 如果页面包含模块标题和课程表格，认为是完整的
    return html.contains('模块') &&
        (html.contains('课程名称') || html.contains('课程号'));
  }
}
