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
}
