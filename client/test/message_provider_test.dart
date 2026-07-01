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

  test('loadMessages can restore cached messages before refreshing latest',
      () async {
    final dio = Dio();
    final seenConversationIds = <String>[];
    final seenAfterIds = <dynamic>[];
    final requestCounts = <String, int>{};
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              options.path.startsWith('/messages/conversations/')) {
            final conversationId = options.path.split('/').last;
            final afterId = options.queryParameters['after_id'];
            requestCounts[conversationId] =
                (requestCounts[conversationId] ?? 0) + 1;
            seenConversationIds.add(conversationId);
            seenAfterIds.add(afterId);
            final isSecondConversation42Request =
                conversationId == '42' && requestCounts[conversationId] == 2;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: isSecondConversation42Request
                    ? [
                        {
                          'id': 2,
                          'conversation_id': 42,
                          'sender_id': 8,
                          'content': 'cached refresh',
                          'created_at': '2026-06-14T08:15:00Z',
                        },
                      ]
                    : [
                        {
                          'id': conversationId == '42' ? 1 : 100,
                          'conversation_id': int.parse(conversationId),
                          'sender_id': 3,
                          'content': 'initial $conversationId',
                          'created_at': '2026-06-14T08:14:00Z',
                        },
                      ],
              ),
            );
            return;
          }
          if (options.method == 'POST' &&
              options.path.startsWith('/messages/conversations/') &&
              options.path.endsWith('/read')) {
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
    await provider.loadMessages(7);

    final cachedLoad = provider.loadMessages(42, preferCache: true);
    expect(provider.currentConversationId, 42);
    expect(provider.messages.map((message) => message.id), [1]);

    await cachedLoad;

    expect(seenConversationIds, ['42', '7', '42']);
    expect(seenAfterIds, [null, null, null]);
    expect(provider.messages.map((message) => message.id), [1, 2]);
  });

  test('loadMessages fetches around target message when cache misses it',
      () async {
    final dio = Dio();
    final seenConversationIds = <String>[];
    final seenAroundIds = <dynamic>[];
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              options.path.startsWith('/messages/conversations/')) {
            final conversationId = options.path.split('/').last;
            final aroundId = options.queryParameters['around_id'];
            seenConversationIds.add(conversationId);
            seenAroundIds.add(aroundId);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: aroundId == 9
                    ? [
                        {
                          'id': 7,
                          'conversation_id': 42,
                          'sender_id': 3,
                          'content': 'before target',
                          'created_at': '2026-06-14T08:12:00Z',
                        },
                        {
                          'id': 8,
                          'conversation_id': 42,
                          'sender_id': 8,
                          'content': 'near target',
                          'created_at': '2026-06-14T08:13:00Z',
                        },
                        {
                          'id': 9,
                          'conversation_id': 42,
                          'sender_id': 3,
                          'content': 'target',
                          'created_at': '2026-06-14T08:14:00Z',
                        },
                      ]
                    : [
                        {
                          'id': conversationId == '42' ? 1 : 100,
                          'conversation_id': int.parse(conversationId),
                          'sender_id': 3,
                          'content': 'initial $conversationId',
                          'created_at': '2026-06-14T08:10:00Z',
                        },
                      ],
              ),
            );
            return;
          }
          if (options.method == 'POST' &&
              options.path.startsWith('/messages/conversations/') &&
              options.path.endsWith('/read')) {
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
    await provider.loadMessages(7);
    await provider.loadMessages(42, preferCache: true, aroundMessageId: 9);

    expect(seenConversationIds, ['42', '7', '42']);
    expect(seenAroundIds, [null, null, 9]);
    expect(provider.messages.map((message) => message.id), [7, 8, 9]);
  });

  test('stores and clears message drafts by target user', () {
    final provider = MessageProvider(Dio());

    provider.updateDraft(3, 'draft');
    expect(provider.draftFor(3), 'draft');

    provider.clearDraft(3);
    expect(provider.draftFor(3), '');
  });

  test('tracks loaded conversations and sums unread private messages',
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
                    'id': 1,
                    'user1_id': 3,
                    'user2_id': 8,
                    'last_message_at': '2026-06-14T08:14:00Z',
                    'unread_count': 2,
                  },
                  {
                    'id': 2,
                    'user1_id': 4,
                    'user2_id': 8,
                    'last_message_at': '2026-06-14T08:15:00Z',
                    'unread_count': 3,
                  },
                ],
              ),
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

    expect(provider.hasLoadedConversations, isFalse);

    await provider.loadConversations(silent: true);

    expect(provider.hasLoadedConversations, isTrue);
    expect(provider.unreadMessageCount, 5);
  });
}
