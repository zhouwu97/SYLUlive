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
}
