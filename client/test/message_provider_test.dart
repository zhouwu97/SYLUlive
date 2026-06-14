import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/message_provider.dart';

void main() {
  test('resolves an existing conversation before loading its messages',
      () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              options.path == '/messages/conversations') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: [
                  {
                    'id': 42,
                    'user1_id': 3,
                    'user2_id': 8,
                    'last_message_at': '2026-06-14T08:14:00Z',
                  },
                ],
              ),
            );
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations/42') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: [
                  {
                    'id': 99,
                    'conversation_id': 42,
                    'sender_id': 3,
                    'content': 'hello',
                    'created_at': '2026-06-14T08:14:00Z',
                  },
                ],
              ),
            );
            return;
          }
          if (options.method == 'POST' &&
              options.path == '/messages/conversations/42/read') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200),
            );
            return;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              message: 'Unexpected request: ${options.method} ${options.path}',
            ),
          );
        },
      ),
    );

    final provider = MessageProvider(dio);

    final conversationId = await provider.openConversationWithUser(
      currentUserId: 8,
      targetUserId: 3,
    );

    expect(conversationId, 42);
    expect(provider.currentConversationId, 42);
    expect(provider.messages.single.content, 'hello');
  });
}
