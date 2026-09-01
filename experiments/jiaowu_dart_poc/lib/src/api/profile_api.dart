import 'package:dio/dio.dart';

import '../auth/login_page_detector.dart';
import '../core/jiaowu_endpoints.dart';
import '../core/jiaowu_headers.dart';
import '../error/jiaowu_exception.dart';
import '../model/student_profile.dart';
import '../parser/profile_parser.dart';
import '../session/jiaowu_session.dart';

/// 学生信息接口，保持 API 请求与 HTML 解析分层。
final class ProfileApi {
  ProfileApi({required Dio dio, required JiaowuSession session})
      : _dio = dio,
        _session = session;

  final Dio _dio;
  final JiaowuSession _session;

  Future<StudentProfile> fetch({required String studentId}) async {
    try {
      final response = await _dio.get<String>(
        JiaowuEndpoints.studentInfo,
        queryParameters: {
          'gnmkdm': 'N100801',
          'layout': 'default',
          'su': studentId,
        },
        options: Options(
          headers: JiaowuHeaders.profile,
          responseType: ResponseType.plain,
          followRedirects: false,
        ),
      );
      final body = response.data ?? '';
      final status = response.statusCode ?? 0;
      if (status == 901 ||
          status == 302 ||
          LoginPageDetector.isLoginPage(body)) {
        _session.markExpired();
        throw const SessionExpiredException();
      }
      if (status != 200) {
        throw NetworkException(
          message: '获取学生信息失败，学校返回状态码 $status',
          code: 'PROFILE_FETCH_FAILED',
        );
      }
      return ProfileParser.parse(body);
    } on JiaowuException {
      rethrow;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        throw const RequestTimeoutException(message: '获取学生信息超时');
      }
      throw NetworkException(message: '获取学生信息失败，请检查网络连接', cause: error);
    }
  }
}
