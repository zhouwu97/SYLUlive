import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

void main() {
  test('列表服务传递筛选参数并解析分页响应', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    RequestOptions? captured;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          captured = options;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'items': <dynamic>[],
                'page': 2,
                'page_size': 10,
                'total': 11,
              },
            ),
          );
        },
      ),
    );

    final service = ExamPaperService(dio);
    final result = await service.list(
      keyword: '高数',
      academicYear: '2025-2026',
      semester: 'first',
      examType: 'final',
      sort: 'downloads',
      page: 2,
      pageSize: 10,
    );

    expect(result.page, 2);
    expect(result.hasMore, isFalse);
    expect(captured?.path, '/exam-papers');
    expect(captured?.queryParameters['keyword'], '高数');
    expect(captured?.queryParameters['sort'], 'downloads');
    expect(captured?.queryParameters['page_size'], 10);
  });

  test('服务端机器错误码转换为可判断的异常', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 403,
                data: {
                  'error': '完成教务认证后才能使用试卷库',
                  'code': 'edu_verification_required',
                },
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    final service = ExamPaperService(dio);
    expect(
      service.list(),
      throwsA(
        isA<ExamPaperApiException>()
            .having((error) => error.code, 'code', 'edu_verification_required')
            .having((error) => error.message, 'message', '完成教务认证后才能使用试卷库'),
      ),
    );
  });

  test('PDF 二进制接口仍能解析服务端 JSON 错误码', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 403,
                data: Uint8List.fromList(
                  utf8.encode(
                    jsonEncode({
                      'error': '无权预览该试卷',
                      'code': 'exam_paper_forbidden',
                    }),
                  ),
                ),
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    final service = ExamPaperService(dio);
    expect(
      service.downloadPreview(_paper(1, '待审核试卷')),
      throwsA(
        isA<ExamPaperApiException>()
            .having((error) => error.code, 'code', 'exam_paper_forbidden')
            .having((error) => error.message, 'message', '无权预览该试卷'),
      ),
    );
  });

  test('管理员列表自动加载全部分页', () async {
    final requestedPages = <int>[];
    final dio = Dio(BaseOptions(baseUrl: 'http://test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final page = options.queryParameters['page'] as int;
          requestedPages.add(page);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'items': [
                  _paperJson(page, '试卷$page'),
                ],
                'page': page,
                'page_size': 1,
                'total': 2,
              },
            ),
          );
        },
      ),
    );

    final result = await ExamPaperService(dio).adminListAll(
      status: 'published',
      pageSize: 1,
    );

    expect(requestedPages, [1, 2]);
    expect(result.map((paper) => paper.title), ['试卷1', '试卷2']);
  });
}

ExamPaper _paper(int id, String title) {
  return ExamPaper.fromJson(_paperJson(id, title));
}

Map<String, dynamic> _paperJson(int id, String title) {
  return {
    'id': id,
    'status': 'published',
    'source': 'user',
    'course_name': title,
    'academic_year': '2025-2026',
    'semester': 'first',
    'exam_type': 'final',
    'title': title,
    'file_size': 1024,
    'download_count': 0,
    'created_at': '2026-07-10T10:00:00Z',
    'contributor': {
      'id': 1,
      'avatar': '',
      'nickname': '测试用户',
      'level': 1,
    },
  };
}
