import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/ai_assistant_service.dart';

void main() {
  test('从认证共享客户端读取 capabilities 契约', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.path, '/ai/capabilities');
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'enabled': true,
                'access_allowed': true,
                'chat_enabled': false,
                'features': <String, dynamic>{},
                'quota': {
                  'limit': 3,
                  'remaining': 3,
                  'window_seconds': 3600,
                },
                'max_message_chars': 20,
              },
            ),
          );
        },
      ),
    );

    final result = await AiAssistantService(dio).getCapabilities();
    expect(result.isVisible, isTrue);
    expect(result.quota.limit, 3);
    expect(result.maxMessageChars, 20);
  });

  test('创建 Run 将 429 配额错误转换为可识别异常', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 429,
                data: {
                  'code': 'ai_quota_exceeded',
                  'message': '最近 60 分钟的可用次数已用完',
                  'retryable': true,
                },
              ),
            ),
          );
        },
      ),
    );

    await expectLater(
      AiAssistantService(dio).createRun(
        conversationId: '',
        clientRequestId: '00000000-0000-4000-8000-000000000001',
        message: '奖学金',
      ),
      throwsA(
        isA<AiAssistantServiceException>()
            .having((error) => error.code, 'code', 'ai_quota_exceeded')
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('来源正文按 chunk id 缓存并合并并发请求', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    var requestCount = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestCount++;
          expect(options.path, '/ai/sources/chunks/26');
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'chunk_id': 26,
                'document_id': 2,
                'title': '补考成绩规则',
                'content': '补考正文',
              },
            ),
          );
        },
      ),
    );
    final service = AiAssistantService(dio);

    final firstPair = await Future.wait([
      service.getSourceContent(26),
      service.getSourceContent(26),
    ]);
    final cached = await service.getSourceContent(26);

    expect(requestCount, 1);
    expect(firstPair.first.content, '补考正文');
    expect(identical(firstPair.first, firstPair.last), isTrue);
    expect(identical(firstPair.first, cached), isTrue);
  });

  test('从 Run 来源聚合接口恢复来源 DTO', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.path, '/ai/runs/run-1/sources');
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'sources': [
                  {
                    'type': 'policy',
                    'primary_chunk_id': 18,
                    'chunk_ids': [18, 19],
                    'document_id': 4,
                    'title': '奖助学金管理办法',
                  },
                ],
                'personal_data_evidence': [
                  {
                    'source': 'hy3_mcp',
                    'dataset': 'academic_analysis',
                    'analysis_input': {
                      'courses': [
                        {
                          'course_name': '信号与系统',
                          'grade': 58,
                          'credits': 3,
                          'is_required': true,
                          'passed': false,
                        },
                      ],
                      'earned_credits': 25.5,
                      'required_credits': 25.5,
                      'erke_earned': 0,
                      'erke_required': 0,
                    },
                  },
                ],
              },
            ),
          );
        },
      ),
    );

    final sources = await AiAssistantService(dio).getRunSources('run-1');

    expect(sources.sources, hasLength(1));
    expect(sources.sources.single.chunkId, 18);
    expect(sources.sources.single.chunkIds, [18, 19]);
    expect(sources.sources.single.title, '奖助学金管理办法');
    expect(sources.personalDataEvidence, hasLength(1));
    expect(
      sources.personalDataEvidence.single.academicCourses.single.name,
      '信号与系统',
    );
    expect(
      sources.personalDataEvidence.single.academicCourses.single.detail,
      '成绩 58 · 3 学分 · 必修 · 未通过',
    );
  });

  test('一次性授权只提交 Run、scope 和决定', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          expect(options.method, 'POST');
          expect(options.path, '/ai/runs/run-1/consent');
          expect(options.data, <String, dynamic>{
            'scope': 'ai_personal_data_access',
            'granted': true,
          });
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 202,
              data: const <String, dynamic>{'run_id': 'run-1'},
            ),
          );
        },
      ),
    );

    await AiAssistantService(dio).submitRunConsent(
      runId: 'run-1',
      scope: 'ai_personal_data_access',
      granted: true,
    );
  });

  test('连接超时用同一 request id 自动重试并接受 202', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    final seenRequestIds = <String>[];
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          seenRequestIds
              .add((options.data as Map)['client_request_id'] as String);
          expect(
            options.headers['X-Client-Request-ID'],
            '00000000-0000-4000-8000-000000000002',
          );
          if (attempts == 1) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionTimeout,
            ));
            return;
          }
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 202,
              data: {
                'run': {
                  'id': 'run-1',
                  'conversation_id': 'conv-1',
                  'state': 'created',
                  'state_version': 1,
                },
                'duplicate': false,
              },
            ),
          );
        },
      ),
    );

    final creation = await AiAssistantService(dio).createRun(
      conversationId: '',
      clientRequestId: '00000000-0000-4000-8000-000000000002',
      message: '挂科了怎么办',
    );

    expect(attempts, 2);
    expect(creation.run.id, 'run-1');
    expect(creation.duplicate, isFalse);
    // 重试必须复用同一个幂等键，否则服务端会创建出第二个 Run。
    expect(seenRequestIds.toSet(), {'00000000-0000-4000-8000-000000000002'});
  });

  test('响应丢失后重试命中服务端幂等，只存在一个 Run', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          if (attempts == 1) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.receiveTimeout,
            ));
            return;
          }
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'run': {
                  'id': 'run-existing',
                  'conversation_id': 'conv-1',
                  'state': 'generating',
                  'state_version': 3,
                },
                'duplicate': true,
              },
            ),
          );
        },
      ),
    );

    final creation = await AiAssistantService(dio).createRun(
      conversationId: 'conv-1',
      clientRequestId: '00000000-0000-4000-8000-000000000003',
      message: '挂科了怎么办',
    );

    expect(creation.duplicate, isTrue);
    expect(creation.run.id, 'run-existing');
  });

  test('业务拒绝状态码不自动重试', () async {
    for (final status in [400, 401, 403, 422, 429]) {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
      var attempts = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            attempts++;
            handler.reject(DioException(
              requestOptions: options,
              response: Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: status,
                data: {'code': 'rejected', 'message': '被拒绝'},
              ),
            ));
          },
        ),
      );

      await expectLater(
        AiAssistantService(dio).createRun(
          conversationId: '',
          clientRequestId: '00000000-0000-4000-8000-000000000004',
          message: '挂科了怎么办',
        ),
        throwsA(isA<AiAssistantServiceException>()),
      );
      expect(attempts, 1, reason: 'HTTP $status 不应自动重试');
    }
  });

  test('连续网络失败保留可重试标记和具体原因', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'));
    var attempts = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          attempts++;
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          ));
        },
      ),
    );

    await expectLater(
      AiAssistantService(dio).createRun(
        conversationId: '',
        clientRequestId: '00000000-0000-4000-8000-000000000005',
        message: '挂科了怎么办',
      ),
      throwsA(
        isA<AiAssistantServiceException>()
            .having((error) => error.code, 'code', 'network_connection_timeout')
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
    expect(attempts, 2);
  });

  test('isTransientCreateRunError 只对链路故障和 5xx 返回 true', () {
    final options = RequestOptions(path: '/ai/runs');
    for (final type in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.connectionError,
    ]) {
      expect(
        isTransientCreateRunError(
            DioException(requestOptions: options, type: type)),
        isTrue,
      );
    }
    expect(
      isTransientCreateRunError(DioException(
        requestOptions: options,
        response: Response<dynamic>(requestOptions: options, statusCode: 503),
      )),
      isTrue,
    );
    for (final status in [400, 401, 403, 422, 429]) {
      expect(
        isTransientCreateRunError(DioException(
          requestOptions: options,
          response:
              Response<dynamic>(requestOptions: options, statusCode: status),
        )),
        isFalse,
        reason: 'HTTP $status',
      );
    }
    expect(
      isTransientCreateRunError(
          DioException(requestOptions: options, type: DioExceptionType.cancel)),
      isFalse,
    );
  });
}
