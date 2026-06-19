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

  test('refreshMessages fetches only messages after the latest id', () async {
    final dio = Dio();
    final seenAfterIds = <dynamic>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              options.path == '/messages/conversations/42') {
            final afterId = options.queryParameters['after_id'];
            seenAfterIds.add(afterId);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: afterId == null
                    ? [
                        {
                          'id': 1,
                          'conversation_id': 42,
                          'sender_id': 3,
                          'content': 'first',
                          'created_at': '2026-06-14T08:14:00Z',
                        },
                        {
                          'id': 2,
                          'conversation_id': 42,
                          'sender_id': 8,
                          'content': 'second',
                          'created_at': '2026-06-14T08:15:00Z',
                        },
                      ]
                    : [
                        {
                          'id': 3,
                          'conversation_id': 42,
                          'sender_id': 3,
                          'content': 'third',
                          'created_at': '2026-06-14T08:16:00Z',
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
    await provider.loadMessages(42);
    await provider.refreshMessages();

    expect(seenAfterIds, [null, 2]);
    expect(provider.messages.map((message) => message.id), [1, 2, 3]);
  });

  test('loadOlderMessages uses the oldest loaded message as before_id',
      () async {
    final dio = Dio();
    final seenBeforeIds = <dynamic>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              options.path == '/messages/conversations/42') {
            final beforeId = options.queryParameters['before_id'];
            seenBeforeIds.add(beforeId);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: beforeId == null
                    ? List.generate(
                        30,
                        (index) => {
                          'id': 10 + index,
                          'conversation_id': 42,
                          'sender_id': index.isEven ? 3 : 8,
                          'content': 'message-${10 + index}',
                          'created_at': '2026-06-14T08:14:00Z',
                        },
                      )
                    : [
                        {
                          'id': 9,
                          'conversation_id': 42,
                          'sender_id': 3,
                          'content': 'nine',
                          'created_at': '2026-06-14T08:13:00Z',
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
    await provider.loadMessages(42);
    await provider.loadOlderMessages();

    expect(seenBeforeIds, [null, 10]);
    expect(provider.messages.first.id, 9);
    expect(provider.messages[1].id, 10);
    expect(provider.messages.last.id, 39);
  });

  test('stores and clears message drafts by target user', () {
    final provider = MessageProvider(Dio());

    provider.updateDraft(3, 'draft');
    expect(provider.draftFor(3), 'draft');

    provider.clearDraft(3);
    expect(provider.draftFor(3), '');
  });
}
