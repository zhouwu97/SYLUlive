import 'dart:convert';
import 'package:html/parser.dart' as html_parser;
import '../parser/credit_requirement_json_parser.dart';
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
          'gnmkdm': 'N105505',
          'layout': 'default',
        },
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          headers: {
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Referer': 'https://jxw.sylu.edu.cn/xtgl/index_initMenu.html',
          },
          validateStatus: (status) =>
              status != null && (status < 500 || status == 901),
        ),
      );

      final entryBody = entryResponse.data;
      // 检查会话过期
      if (entryResponse.statusCode == 302 ||
          entryResponse.statusCode == 901 ||
          LoginPageDetector.isLoginPage(entryBody ?? '')) {
        _session.markExpired();
        throw const SessionExpiredException();
      }

      if (entryBody == null || entryBody.isEmpty) {
        throw const ParseException(
          message: '学分要求响应为空',
          code: 'EMPTY_RESPONSE',
        );
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
      if (queryParams.length != 3) {
        final requirement = CreditRequirementParser.parse(entryBody);
        if (!requirement.success) {
          throw ParseException(
            message: '学分要求查询选项不完整，学校协议可能发生变化',
            code: 'CREDIT_REQUIREMENT_QUERY_PROTOCOL_CHANGED',
          );
        }
        return requirement;
      }

      // 第二步：使用查询参数获取详细数据
      final detailResponse = await _dio.post<String>(
        '/xjyj/xjyj_cxXjyjjdlb.html',
        queryParameters: {
          'gnmkdm': 'N105505',
        },
        data: queryParams,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          headers: {
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'Content-Type': 'application/x-www-form-urlencoded',
            'Referer': 'https://jxw.sylu.edu.cn/xjyj/xjyj_cxXjyjIndex.html',
          },
          validateStatus: (status) =>
              status != null && (status < 500 || status == 901),
        ),
      );

      final detailBody = detailResponse.data;
      // 检查会话过期
      if (detailResponse.statusCode == 302 ||
          detailResponse.statusCode == 901 ||
          LoginPageDetector.isLoginPage(detailBody ?? '')) {
        _session.markExpired();
        throw const SessionExpiredException();
      }

      if (detailBody == null || detailBody.isEmpty) {
        throw const ParseException(
          message: '学分要求详细响应为空',
          code: 'EMPTY_RESPONSE',
        );
      }

      if (detailResponse.statusCode != 200) {
        throw NetworkException(
          message: '学分要求详细接口返回状态码 ${detailResponse.statusCode}',
          code: 'REMOTE_SYSTEM_UNAVAILABLE',
        );
      }

      CreditRequirement requirement;
      try {
        requirement = CreditRequirementJsonParser.parse(jsonDecode(detailBody));
      } on FormatException {
        // 仅兼容学校确实返回完整静态 HTML 的情况。
        requirement = CreditRequirementParser.parse(detailBody);
      }
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

  /// 只取三个当前选项，不把其他隐藏字段带入学校查询。
  Map<String, String> _extractQueryParams(String html) {
    final document = html_parser.parse(html);
    final params = <String, String>{};
    for (final key in ['jg_id', 'njdm_id', 'zyh_id']) {
      final select = document.querySelector('select#$key, select[name="$key"]');
      final option = select?.querySelector('option[selected]');
      final value = option?.attributes['value']?.trim();
      if (value != null && value.isNotEmpty) params[key] = value;
    }
    return params;
  }
}
