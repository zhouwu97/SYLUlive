import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/exam_paper.dart';
import 'package:shenliyuan/services/exam_paper_service.dart';

class _RecordedRequest {
  final String adapter;
  final RequestOptions options;

  const _RecordedRequest(this.adapter, this.options);
}

class _QueuedResponse {
  final int statusCode;
  final Object? data;
  final DioExceptionType? exceptionType;

  const _QueuedResponse(
    this.statusCode,
    this.data, {
    this.exceptionType,
  });
}

/// 记录 Dio 最终发出的请求，并按顺序返回预设响应。
class _RecordingAdapter implements HttpClientAdapter {
  final String name;
  final List<_RecordedRequest> requests;
  final List<_QueuedResponse> _responses = [];

  _RecordingAdapter(this.name, this.requests);

  void enqueueJson(int statusCode, Object? data) {
    _responses.add(_QueuedResponse(statusCode, data));
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(_RecordedRequest(name, options));
    await requestStream?.drain<void>();
    if (_responses.isEmpty) {
      throw StateError('$name 缺少预设响应: ${options.method} ${options.uri}');
    }
    final response = _responses.removeAt(0);
    if (response.exceptionType != null) {
      throw DioException(
        requestOptions: options,
        type: response.exceptionType!,
        message: 'socket failed',
      );
    }
    return ResponseBody.fromString(
      jsonEncode(response.data),
      response.statusCode,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

void main() {
  test('上传先创建会话，再直传文件，最后完成会话', () async {
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, {
        'session_id': 'session-1',
        'upload_url': 'https://sylulive.online/v1/uploads/session-1',
        'upload_token': 'signed-upload-token',
        'expires_at': '2026-07-13T10:10:00Z',
      })
      ..enqueueJson(201, _paperJson(9, '高等数学'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'signed-receipt'});
    final apiDio = Dio(
      BaseOptions(
        baseUrl: 'https://couqie.ccwu.cc/api',
        headers: {
          'Authorization': 'Bearer main-jwt',
          'Cookie': 'session=main-cookie',
        },
      ),
    )..httpClientAdapter = apiAdapter;
    apiDio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers['X-Main-Interceptor'] = 'present';
          handler.next(options);
        },
      ),
    );
    final storageDio = Dio()..httpClientAdapter = storageAdapter;

    final paper = await ExamPaperService(
      apiDio,
      storageDio: storageDio,
    ).upload(
      file: PlatformFile(
        name: '高等数学.pdf',
        size: 8,
        bytes: Uint8List.fromList(utf8.encode('%PDF-1.4')),
      ),
      courseName: ' 高等数学 ',
      academicYear: '2025-2026',
      semester: 'first',
      examType: 'final',
      privacyConfirmed: true,
    );

    expect(paper.id, 9);
    expect(requests.map((request) => request.adapter), [
      'api',
      'storage',
      'api',
    ]);
    expect(requests[0].options.path, '/exam-papers/upload-sessions');
    expect(requests[0].options.data, {
      'course_name': '高等数学',
      'academic_year': '2025-2026',
      'semester': 'first',
      'exam_type': 'final',
      'privacy_confirmed': true,
      'file_size': 8,
    });
    expect(requests[1].options.uri.host, 'sylulive.online');
    expect(
      requests[1].options.headers['Authorization'],
      'Bearer signed-upload-token',
    );
    expect(requests[1].options.headers['Cookie'], isNull);
    expect(requests[1].options.headers['X-Main-Interceptor'], isNull);
    expect(requests[1].options.followRedirects, isFalse);
    expect(requests[2].options.path,
        '/exam-papers/upload-sessions/session-1/complete');
    expect(requests[2].options.data, {'receipt': 'signed-receipt'});
  });

  test('完成请求失败后重试只重新完成会话，不重复上传文件', () async {
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson())
      ..enqueueJson(500, {
        'code': 'internal_error',
        'error': '完成试卷投稿失败',
      })
      ..enqueueJson(201, _paperJson(10, '数据结构'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'receipt-for-retry'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final service = ExamPaperService(apiDio, storageDio: storageDio);
    final file = _pdfPlatformFile('数据结构.pdf');

    await expectLater(
      _uploadPaper(service, file, courseName: '数据结构'),
      throwsA(
        isA<ExamPaperApiException>()
            .having((error) => error.code, 'code', 'internal_error'),
      ),
    );
    final paper = await _uploadPaper(service, file, courseName: '数据结构');

    expect(paper.id, 10);
    expect(requests.map((request) => request.adapter), [
      'api',
      'storage',
      'api',
      'api',
    ]);
    expect(
      requests.last.options.path,
      '/exam-papers/upload-sessions/session-1/complete',
    );
  });

  test('上传进度只由文件服务器请求产生', () async {
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson())
      ..enqueueJson(201, _paperJson(11, '离散数学'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'receipt-with-progress'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;
    final progressRequestCounts = <int>[];

    await _uploadPaper(
      ExamPaperService(apiDio, storageDio: storageDio),
      _pdfPlatformFile('离散数学.pdf'),
      courseName: '离散数学',
      onSendProgress: (sent, total) {
        progressRequestCounts.add(requests.length);
      },
    );

    expect(progressRequestCounts, isNotEmpty);
    expect(progressRequestCounts, everyElement(2));
  });

  test('path 文件可以完成两阶段直传', () async {
    final directory = await Directory.systemTemp.createTemp('paper-upload-');
    addTearDown(() => directory.delete(recursive: true));
    final localFile = File('${directory.path}${Platform.pathSeparator}试卷.pdf');
    await localFile.writeAsBytes(utf8.encode('%PDF-1.4'));
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(201, _uploadSessionJson())
      ..enqueueJson(201, _paperJson(12, '大学物理'));
    final storageAdapter = _RecordingAdapter('storage', requests)
      ..enqueueJson(201, {'receipt': 'path-receipt'});
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;

    final paper = await _uploadPaper(
      ExamPaperService(apiDio, storageDio: storageDio),
      PlatformFile(
        name: '试卷.pdf',
        size: await localFile.length(),
        path: localFile.path,
      ),
      courseName: '大学物理',
    );

    expect(paper.id, 12);
    expect(requests.map((request) => request.adapter), [
      'api',
      'storage',
      'api',
    ]);
  });

  test('拒绝把上传令牌发送到非文件服务域名', () async {
    final requests = <_RecordedRequest>[];
    final apiAdapter = _RecordingAdapter('api', requests)
      ..enqueueJson(
          201,
          _uploadSessionJson(
            uploadURL: 'https://attacker.example/v1/uploads/session-1',
          ));
    final storageAdapter = _RecordingAdapter('storage', requests);
    final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
      ..httpClientAdapter = apiAdapter;
    final storageDio = Dio()..httpClientAdapter = storageAdapter;

    await expectLater(
      _uploadPaper(
        ExamPaperService(apiDio, storageDio: storageDio),
        _pdfPlatformFile('恶意地址.pdf'),
      ),
      throwsA(
        isA<ExamPaperApiException>()
            .having((error) => error.code, 'code', 'invalid_storage_url'),
      ),
    );
    expect(requests.map((request) => request.adapter), ['api']);
  });

  test('拒绝非标准端口和不匹配会话的文件服务地址', () async {
    for (final uploadURL in [
      'https://sylulive.online:8443/v1/uploads/session-1',
      'https://sylulive.online/v1/uploads/another-session',
      'http://sylulive.online/v1/uploads/session-1',
    ]) {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests)
        ..enqueueJson(201, _uploadSessionJson(uploadURL: uploadURL));
      final storageAdapter = _RecordingAdapter('storage', requests);
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;

      await expectLater(
        _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('地址约束.pdf'),
        ),
        throwsA(
          isA<ExamPaperApiException>()
              .having((error) => error.code, 'code', 'invalid_storage_url'),
        ),
        reason: uploadURL,
      );
      expect(requests.map((request) => request.adapter), ['api']);
    }
  });

  test('三阶段服务错误均转换为可判断的上传异常', () async {
    Future<ExamPaperApiException> runFailure({
      required List<_QueuedResponse> apiResponses,
      required List<_QueuedResponse> storageResponses,
    }) async {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests);
      final storageAdapter = _RecordingAdapter('storage', requests);
      for (final response in apiResponses) {
        apiAdapter.enqueueJson(response.statusCode, response.data);
      }
      for (final response in storageResponses) {
        storageAdapter.enqueueJson(response.statusCode, response.data);
      }
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;
      try {
        await _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('错误映射.pdf'),
        );
      } on ExamPaperApiException catch (error) {
        return error;
      }
      throw StateError('测试请求应当失败');
    }

    final upgrade = await runFailure(
      apiResponses: const [
        _QueuedResponse(426, {
          'code': 'client_upgrade_required',
          'error': '请升级客户端后上传试卷',
        }),
      ],
      storageResponses: const [],
    );
    expect(upgrade.code, 'client_upgrade_required');
    expect(upgrade.message, contains('升级'));

    final storage = await runFailure(
      apiResponses: [_QueuedResponse(201, _uploadSessionJson())],
      storageResponses: const [
        _QueuedResponse(507, {
          'error': 'insufficient storage',
        }),
      ],
    );
    expect(storage.code, 'insufficient_storage');
    expect(storage.message, '文件服务器空间不足，请稍后重试');

    final expired = await runFailure(
      apiResponses: [
        _QueuedResponse(201, _uploadSessionJson()),
        const _QueuedResponse(410, {
          'code': 'upload_session_expired',
          'error': '上传会话已过期，请重新上传',
        }),
      ],
      storageResponses: const [
        _QueuedResponse(201, {'receipt': 'expired-receipt'}),
      ],
    );
    expect(expired.code, 'upload_session_expired');
    expect(expired.message, contains('过期'));

    final storageNetwork = await runFailure(
      apiResponses: [_QueuedResponse(201, _uploadSessionJson())],
      storageResponses: const [
        _QueuedResponse(
          0,
          null,
          exceptionType: DioExceptionType.connectionError,
        ),
      ],
    );
    expect(storageNetwork.code, 'storage_upload_failed');
    expect(storageNetwork.message, '文件上传失败，请检查网络后重试');

    final completeNetwork = await runFailure(
      apiResponses: [
        _QueuedResponse(201, _uploadSessionJson()),
        const _QueuedResponse(
          0,
          null,
          exceptionType: DioExceptionType.connectionError,
        ),
      ],
      storageResponses: const [
        _QueuedResponse(201, {'receipt': 'network-receipt'}),
      ],
    );
    expect(completeNetwork.code, 'upload_complete_failed');
    expect(completeNetwork.message, contains('文件已上传'));
  });

  test('文件服务真实错误串映射为稳定错误码和中文提示', () async {
    final cases = <({
      String serverError,
      int statusCode,
      String expectedCode,
      String expectedMessage,
    })>[
      (
        serverError: 'unauthorized',
        statusCode: 401,
        expectedCode: 'upload_session_expired',
        expectedMessage: '上传凭证已失效，请重新上传',
      ),
      (
        serverError: 'upload_session_expired',
        statusCode: 410,
        expectedCode: 'upload_session_expired',
        expectedMessage: '上传会话已过期，请重新上传',
      ),
      (
        serverError: 'upload_session_invalid',
        statusCode: 409,
        expectedCode: 'upload_session_invalid',
        expectedMessage: '上传会话已失效，请重新上传',
      ),
      (
        serverError: 'upload_retry_exhausted',
        statusCode: 429,
        expectedCode: 'upload_retry_exhausted',
        expectedMessage: '该文件上传失败次数过多，请重新选择文件',
      ),
      (
        serverError: 'upload_unclaimed_quota_exceeded',
        statusCode: 429,
        expectedCode: 'upload_storage_quota_exceeded',
        expectedMessage: '未完成的上传过多，请稍后重试',
      ),
      (
        serverError: 'upload_session_in_progress',
        statusCode: 409,
        expectedCode: 'upload_session_in_progress',
        expectedMessage: '该文件正在上传，请稍后重试',
      ),
      (
        serverError: 'file_size_mismatch',
        statusCode: 422,
        expectedCode: 'file_size_mismatch',
        expectedMessage: '文件大小发生变化，请重新选择 PDF',
      ),
      (
        serverError: 'file too large',
        statusCode: 413,
        expectedCode: 'file_too_large',
        expectedMessage: 'PDF 不能超过 20 MiB',
      ),
      (
        serverError: 'invalid pdf',
        statusCode: 422,
        expectedCode: 'invalid_pdf',
        expectedMessage: 'PDF 文件无效或已加密，请更换文件',
      ),
      (
        serverError: 'encrypted pdf',
        statusCode: 422,
        expectedCode: 'invalid_pdf',
        expectedMessage: 'PDF 文件无效或已加密，请更换文件',
      ),
      (
        serverError: 'insufficient storage',
        statusCode: 507,
        expectedCode: 'insufficient_storage',
        expectedMessage: '文件服务器空间不足，请稍后重试',
      ),
      (
        serverError: 'validation busy',
        statusCode: 503,
        expectedCode: 'validation_busy',
        expectedMessage: '文件校验繁忙，请稍后重试',
      ),
      (
        serverError: 'storage unavailable',
        statusCode: 500,
        expectedCode: 'storage_unavailable',
        expectedMessage: '文件服务器暂不可用，请稍后重试',
      ),
    ];

    for (final testCase in cases) {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests)
        ..enqueueJson(201, _uploadSessionJson());
      final storageAdapter = _RecordingAdapter('storage', requests)
        ..enqueueJson(testCase.statusCode, {'error': testCase.serverError});
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;

      await expectLater(
        _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('错误映射.pdf'),
        ),
        throwsA(
          isA<ExamPaperApiException>()
              .having(
                (error) => error.code,
                'code',
                testCase.expectedCode,
              )
              .having(
                (error) => error.message,
                'message',
                testCase.expectedMessage,
              ),
        ),
        reason: testCase.serverError,
      );
    }
  });

  test('文件服务未知或非对象错误响应不回显原始内容', () async {
    for (final response in const [
      _QueuedResponse(500, {'error': 'private backend detail'}),
      _QueuedResponse(502, <Object>['private', 'backend', 'detail']),
      _QueuedResponse(400, 'private backend detail'),
    ]) {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests)
        ..enqueueJson(201, _uploadSessionJson());
      final storageAdapter = _RecordingAdapter('storage', requests)
        ..enqueueJson(response.statusCode, response.data);
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;

      await expectLater(
        _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('未知错误.pdf'),
        ),
        throwsA(
          isA<ExamPaperApiException>()
              .having(
                (error) => error.code,
                'code',
                'storage_upload_failed',
              )
              .having(
                (error) => error.message,
                'message',
                '文件上传失败，请稍后重试',
              ),
        ),
      );
    }
  });

  test('拒绝字段类型错误的会话、文件服务和完成响应', () async {
    Future<String> invalidResponseCode({
      required List<_QueuedResponse> apiResponses,
      required List<_QueuedResponse> storageResponses,
    }) async {
      final requests = <_RecordedRequest>[];
      final apiAdapter = _RecordingAdapter('api', requests);
      final storageAdapter = _RecordingAdapter('storage', requests);
      for (final response in apiResponses) {
        apiAdapter.enqueueJson(response.statusCode, response.data);
      }
      for (final response in storageResponses) {
        storageAdapter.enqueueJson(response.statusCode, response.data);
      }
      final apiDio = Dio(BaseOptions(baseUrl: 'https://couqie.ccwu.cc/api'))
        ..httpClientAdapter = apiAdapter;
      final storageDio = Dio()..httpClientAdapter = storageAdapter;
      try {
        await _uploadPaper(
          ExamPaperService(apiDio, storageDio: storageDio),
          _pdfPlatformFile('响应校验.pdf'),
        );
      } on ExamPaperApiException catch (error) {
        return error.code;
      }
      throw StateError('测试响应应当被拒绝');
    }

    expect(
      await invalidResponseCode(
        apiResponses: [
          _QueuedResponse(201, {
            ..._uploadSessionJson(),
            'session_id': 1,
          }),
        ],
        storageResponses: const [],
      ),
      'invalid_upload_session_response',
    );
    expect(
      await invalidResponseCode(
        apiResponses: [_QueuedResponse(201, _uploadSessionJson())],
        storageResponses: const [
          _QueuedResponse(201, {'receipt': 1}),
        ],
      ),
      'invalid_storage_response',
    );
    expect(
      await invalidResponseCode(
        apiResponses: [
          _QueuedResponse(201, _uploadSessionJson()),
          _QueuedResponse(201, {
            ..._paperJson(13, '严格校验'),
            'id': '13',
          }),
        ],
        storageResponses: const [
          _QueuedResponse(201, {'receipt': 'strict-receipt'}),
        ],
      ),
      'invalid_complete_response',
    );
    expect(
      await invalidResponseCode(
        apiResponses: const [_QueuedResponse(201, <Object>[])],
        storageResponses: const [],
      ),
      'invalid_upload_session_response',
    );
    expect(
      await invalidResponseCode(
        apiResponses: [
          _QueuedResponse(201, _uploadSessionJson()),
          _QueuedResponse(201, {
            ..._paperJson(14, '布尔校验'),
            'reward_revocable': 'false',
          }),
        ],
        storageResponses: const [
          _QueuedResponse(201, {'receipt': 'boolean-receipt'}),
        ],
      ),
      'invalid_complete_response',
    );
  });

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
                'academic_years': ['2025-2026', '2024-2025'],
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
    expect(result.academicYears, ['2025-2026', '2024-2025']);
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

  test('我的投稿传递状态并解析全量状态计数', () async {
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
                'page': 1,
                'page_size': 20,
                'total': 1,
                'status_counts': {
                  'all': 3,
                  'pending': 1,
                  'published': 1,
                  'unpublished': 1,
                },
              },
            ),
          );
        },
      ),
    );

    final result = await ExamPaperService(dio).mySubmissions(
      status: 'unpublished',
    );

    expect(captured?.queryParameters['status'], 'unpublished');
    expect(result.statusCounts['all'], 3);
    expect(result.statusCounts['unpublished'], 1);

    await ExamPaperService(dio).mySubmissions(status: 'all');
    expect(captured?.queryParameters['status'], 'all');
  });

  test('管理员列表传递关键词、投稿人与排序参数', () async {
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
                'page': 1,
                'page_size': 20,
                'total': 0,
              },
            ),
          );
        },
      ),
    );

    await ExamPaperService(dio).adminList(
      status: 'pending',
      keyword: '高等数学',
      contributor: '张同学',
      sort: 'latest',
    );

    expect(captured?.queryParameters['keyword'], '高等数学');
    expect(captured?.queryParameters['contributor'], '张同学');
    expect(captured?.queryParameters['sort'], 'latest');
  });

  test('删除投稿发送 DELETE 并解析经验撤销结果', () async {
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
                'message': '投稿已永久删除',
                'exp_revoked': true,
              },
            ),
          );
        },
      ),
    );

    final result = await ExamPaperService(dio).deleteSubmission(12);

    expect(captured?.method, 'DELETE');
    expect(captured?.path, '/exam-papers/my-submissions/12');
    expect(result.message, '投稿已永久删除');
    expect(result.expRevoked, isTrue);
  });

  test('删除投稿的 Dio 错误转换为接口异常', () async {
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
                  'error': '无权删除该投稿',
                  'code': 'exam_paper_delete_forbidden',
                },
              ),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );

    expect(
      ExamPaperService(dio).deleteSubmission(12),
      throwsA(
        isA<ExamPaperApiException>()
            .having(
              (error) => error.code,
              'code',
              'exam_paper_delete_forbidden',
            )
            .having((error) => error.message, 'message', '无权删除该投稿'),
      ),
    );
  });

  test('删除结果缺失字段时使用默认值', () {
    final result = ExamPaperDeleteResult.fromJson(const <String, dynamic>{});

    expect(result.message, '操作成功');
    expect(result.expRevoked, isFalse);
  });

  test('withdraw 保持兼容并发送同一 DELETE', () async {
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
              data: const <String, dynamic>{},
            ),
          );
        },
      ),
    );

    await ExamPaperService(dio).withdraw(27);

    expect(captured?.method, 'DELETE');
    expect(captured?.path, '/exam-papers/my-submissions/27');
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
    'reward_revocable': false,
    'created_at': '2026-07-10T10:00:00Z',
    'contributor': {
      'id': 1,
      'avatar': '',
      'nickname': '测试用户',
      'level': 1,
    },
  };
}

Map<String, dynamic> _uploadSessionJson({
  String uploadURL = 'https://sylulive.online/v1/uploads/session-1',
}) {
  return {
    'session_id': 'session-1',
    'upload_url': uploadURL,
    'upload_token': 'signed-upload-token',
    'expires_at': '2026-07-13T10:10:00Z',
  };
}

PlatformFile _pdfPlatformFile(String name) {
  final bytes = Uint8List.fromList(utf8.encode('%PDF-1.4'));
  return PlatformFile(name: name, size: bytes.length, bytes: bytes);
}

Future<ExamPaper> _uploadPaper(
  ExamPaperService service,
  PlatformFile file, {
  String courseName = '高等数学',
  ProgressCallback? onSendProgress,
}) {
  return service.upload(
    file: file,
    courseName: courseName,
    academicYear: '2025-2026',
    semester: 'first',
    examType: 'final',
    privacyConfirmed: true,
    onSendProgress: onSendProgress,
  );
}
