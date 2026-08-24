import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';

void main() {
  test('resolves an existing conversation before loading its messages',
      () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              options.path == '/messages/users/3/conversation') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'conversation': {
                    'id': 42,
                    'user1_id': 3,
                    'user2_id': 8,
                    'last_message_at': '2026-06-14T08:14:00Z',
                  },
                  'can_send': true,
                  'reason': null,
                },
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

  test('stale conversation lookup cannot replace a newer chat', () async {
    final dio = Dio();
    final lookupGate = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              options.path == '/messages/users/3/conversation') {
            lookupGate.future.then((_) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'conversation': {
                      'id': 42,
                      'user1_id': 3,
                      'user2_id': 8,
                      'last_message_at': '2026-06-14T08:14:00Z',
                    },
                  },
                ),
              );
            });
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations/7') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);

    final staleLookup = provider.openConversationWithUser(
      currentUserId: 8,
      targetUserId: 3,
    );
    await Future<void>.delayed(Duration.zero);
    await provider.loadMessages(7);
    lookupGate.complete();

    expect(await staleLookup, isNull);
    expect(provider.currentConversationId, 7);
    expect(provider.messages, isEmpty);
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
    provider.updateDraftSticker(3, 'sticker-1');
    expect(provider.draftFor(3), 'draft');
    expect(provider.draftStickerFor(3), 'sticker-1');

    provider.updateDraft(3, 'updated');
    expect(provider.draftStickerFor(3), 'sticker-1');

    provider.clearDraft(3);
    expect(provider.draftFor(3), '');
    expect(provider.draftStickerFor(3), isNull);
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

  test('sendMessage inserts a pending message before the request completes',
      () async {
    final dio = Dio();
    final responseGate = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/messages/3') {
            final data = Map<String, dynamic>.from(options.data as Map);
            responseGate.future.then((_) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: _messageJson(
                    id: 101,
                    clientMessageId: data['client_message_id'] as String,
                  ),
                ),
              );
            });
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);

    final send = provider.sendMessage(3, 'hello', senderId: 8);

    expect(provider.messages, hasLength(1));
    expect(provider.messages.single.isPending, isTrue);
    expect(provider.messages.single.content, 'hello');
    expect(provider.messages.single.clientMessageId, isNotEmpty);

    responseGate.complete();
    final confirmed = await send;

    expect(confirmed?.id, 101);
    expect(provider.messages, hasLength(1));
    expect(provider.messages.single.isPending, isFalse);
    expect(provider.messages.single.id, 101);
  });

  test('sendMessage submits text and sticker as one message', () async {
    final dio = Dio();
    Map<String, dynamic>? requestData;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/messages/3') {
            requestData = Map<String, dynamic>.from(options.data as Map);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 201,
                data: {
                  ..._messageJson(
                    id: 102,
                    clientMessageId:
                        requestData!['client_message_id'] as String,
                    content: '晚安',
                  ),
                  'sticker_id': 'sticker-1',
                },
              ),
            );
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);

    final confirmed = await provider.sendMessage(
      3,
      '晚安',
      stickerId: 'sticker-1',
      senderId: 8,
    );

    expect(requestData?['content'], '晚安');
    expect(requestData?['sticker_id'], 'sticker-1');
    expect(provider.messages, hasLength(1));
    expect(confirmed?.isMixedTextSticker, isTrue);
  });

  test('sendFavoriteImageMessage reuses the existing file id without upload',
      () async {
    final dio = Dio();
    Map<String, dynamic>? requestData;
    var uploadRequests = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/upload') {
            uploadRequests++;
            handler.reject(_unexpectedRequest(options));
            return;
          }
          if (options.method == 'POST' && options.path == '/messages/3') {
            requestData = Map<String, dynamic>.from(options.data as Map);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 201,
                data: _messageJson(
                  id: 103,
                  clientMessageId: requestData!['client_message_id'] as String,
                ),
              ),
            );
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);

    final confirmed = await provider.sendFavoriteImageMessage(
      3,
      const EmojiFavoriteItem.custom(fileId: 77),
      senderId: 8,
    );

    expect(confirmed?.id, 103);
    expect(requestData?['file_id'], 77);
    expect(requestData?['content'], '');
    expect(uploadRequests, 0);
  });

  test(
      'sendFavoriteImageMessage with invalid fileId sets messageError and returns null',
      () async {
    final dio = Dio();
    final provider = MessageProvider(dio);

    final result = await provider.sendFavoriteImageMessage(
      3,
      const EmojiFavoriteItem.image('https://example.com/invalid.png'),
      senderId: 8,
    );

    expect(result, isNull);
    expect(provider.messageError, '该收藏数据已失效，请重新收藏');
  });

  test('sendMessage allows multiple requests to remain in flight', () async {
    final dio = Dio();
    final responseGate = Completer<void>();
    var requestIndex = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/messages/3') {
            final currentIndex = ++requestIndex;
            final data = Map<String, dynamic>.from(options.data as Map);
            responseGate.future.then((_) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: _messageJson(
                    id: 200 + currentIndex,
                    clientMessageId: data['client_message_id'] as String,
                    content: data['content'] as String,
                  ),
                ),
              );
            });
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);

    final first = provider.sendMessage(3, 'first', senderId: 8);
    final second = provider.sendMessage(3, 'second', senderId: 8);

    expect(provider.messages, hasLength(2));
    expect(provider.messages.every((message) => message.isPending), isTrue);
    expect(
      provider.messages.map((message) => message.clientMessageId).toSet(),
      hasLength(2),
    );

    responseGate.complete();
    await Future.wait([first, second]);

    expect(provider.messages, hasLength(2));
    expect(provider.messages.every((message) => !message.isPending), isTrue);
  });

  test('retryMessage reuses the original client message id', () async {
    final dio = Dio();
    final clientMessageIds = <String>[];
    var postCount = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/messages/3') {
            postCount++;
            final data = Map<String, dynamic>.from(options.data as Map);
            final clientMessageId = data['client_message_id'] as String;
            clientMessageIds.add(clientMessageId);
            if (postCount == 1) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  message: 'offline',
                ),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: _messageJson(
                    id: 301,
                    clientMessageId: clientMessageId,
                  ),
                ),
              );
            }
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);

    expect(await provider.sendMessage(3, 'retry me', senderId: 8), isNull);
    final failed = provider.messages.single;
    expect(failed.isFailed, isTrue);

    final retry = provider.retryMessage(3, failed.clientMessageId!);
    expect(provider.messages.single.isPending, isTrue);
    final confirmed = await retry;

    expect(confirmed?.id, 301);
    expect(clientMessageIds, hasLength(2));
    expect(clientMessageIds[1], clientMessageIds[0]);
    expect(provider.messages.single.isFailed, isFalse);
  });

  test('fallback sync clears a confirmed pending context', () async {
    final dio = Dio();
    String? clientMessageId;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/messages/3') {
            final data = Map<String, dynamic>.from(options.data as Map);
            clientMessageId = data['client_message_id'] as String;
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'response lost',
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
                  _messageJson(
                    id: 302,
                    clientMessageId: clientMessageId!,
                  ),
                ],
              ),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio)
      ..prepareNewConversation(targetUserId: 3);

    expect(await provider.sendMessage(3, 'response lost', senderId: 8), isNull);
    expect(provider.messages.single.isFailed, isTrue);

    await provider.loadMessages(42);
    expect(provider.messages.single.id, 302);
    expect(provider.messages.single.isFailed, isFalse);

    provider.prepareNewConversation(targetUserId: 3);
    expect(provider.messages, isEmpty);
  });

  test('realtime created merges pending and read updates delivery state',
      () async {
    final dio = Dio();
    final responseGate = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/messages/3') {
            final data = Map<String, dynamic>.from(options.data as Map);
            responseGate.future.then((_) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: _messageJson(
                    id: 401,
                    clientMessageId: data['client_message_id'] as String,
                  ),
                ),
              );
            });
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);

    final send = provider.sendMessage(3, 'hello', senderId: 8);
    final clientMessageId = provider.messages.single.clientMessageId!;
    provider.applyRealtimeEventForTest('message.created', {
      'message': _messageJson(
        id: 401,
        clientMessageId: clientMessageId,
      ),
    });

    expect(provider.currentConversationId, 42);
    expect(provider.messages, hasLength(1));
    expect(provider.messages.single.id, 401);
    expect(provider.messages.single.isPending, isFalse);

    provider.applyRealtimeEventForTest('message.read', {
      'conversation_id': 42,
      'read_by_user_id': 3,
      'read_at': '2026-06-14T08:16:00Z',
    });
    expect(provider.messages.single.readAt, isNotNull);

    responseGate.complete();
    await send;
    expect(provider.messages, hasLength(1));
  });

  test('read receipt only updates messages through its server boundary',
      () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              options.path == '/messages/conversations/42') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: [
                  {
                    'id': 10,
                    'conversation_id': 42,
                    'sender_id': 8,
                    'content': 'first',
                    'created_at': '2026-06-14T08:14:00Z',
                  },
                  {
                    'id': 11,
                    'conversation_id': 42,
                    'sender_id': 8,
                    'content': 'concurrent',
                    'created_at': '2026-06-14T08:16:01Z',
                  },
                ],
              ),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);
    await provider.loadMessages(42);

    provider.applyRealtimeEventForTest('message.read', {
      'conversation_id': 42,
      'read_by_user_id': 3,
      'read_through_message_id': 10,
      'read_at': '2026-06-14T08:16:00Z',
    });

    expect(provider.messages[0].readAt, isNotNull);
    expect(provider.messages[1].readAt, isNull);
  });

  test('duplicate realtime event does not double conversation unread count',
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
                    'last_message_at': '2026-06-14T08:31:00Z',
                    'unread_count': 1,
                    'last_message': {
                      'id': 31,
                      'conversation_id': 42,
                      'sender_id': 3,
                      'content': 'already synchronized',
                      'created_at': '2026-06-14T08:31:00Z',
                    },
                  },
                ],
              ),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);
    await provider.loadConversations();

    provider.applyRealtimeEventForTest('message.created', {
      'message': {
        'id': 31,
        'conversation_id': 42,
        'sender_id': 3,
        'content': 'already synchronized',
        'created_at': '2026-06-14T08:31:00Z',
      },
    });

    expect(provider.conversations.single.unreadCount, 1);
    expect(provider.conversations.single.lastMessage?.id, 31);
  });

  test('send response updates its origin cache after switching conversations',
      () async {
    final dio = Dio();
    final responseGate = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              (options.path == '/messages/conversations/42' ||
                  options.path == '/messages/conversations/7')) {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          if (options.method == 'POST' && options.path == '/messages/3') {
            final data = Map<String, dynamic>.from(options.data as Map);
            responseGate.future.then((_) {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 201,
                  data: _messageJson(
                    id: 501,
                    clientMessageId: data['client_message_id'] as String,
                  ),
                ),
              );
            });
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio);
    await provider.loadMessages(42);

    final send = provider.sendMessage(3, 'from 42', senderId: 8);
    expect(provider.messages.single.isPending, isTrue);
    await provider.loadMessages(7);
    expect(provider.currentConversationId, 7);
    expect(provider.messages, isEmpty);

    responseGate.complete();
    await send;

    expect(provider.currentConversationId, 7);
    expect(provider.messages, isEmpty);
    expect(provider.latestCachedMessageForConversation(42)?.id, 501);
  });

  test('active conversation is independent from the loaded conversation',
      () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' &&
              options.path == '/messages/conversations/42') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: []),
            );
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio)..setActiveConversation(99);

    await provider.loadMessages(42);

    expect(provider.currentConversationId, 42);
    expect(provider.activeConversationId, 99);
    provider.setActiveConversation(null);
    expect(provider.currentConversationId, 42);
    expect(provider.activeConversationId, isNull);
  });

  test('账号 A 的会话列表错误和 finally 不会污染账号 B 的加载状态', () async {
    final dio = Dio();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    var requestIndex = 0;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method != 'GET' ||
              options.path != '/messages/conversations') {
            handler.reject(_unexpectedRequest(options));
            return;
          }
          final index = ++requestIndex;
          if (index == 1) {
            firstStarted.complete();
            firstGate.future.then((_) {
              if (!handler.isCompleted) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.connectionError,
                    message: 'account A offline',
                  ),
                );
              }
            });
            return;
          }
          secondStarted.complete();
          secondGate.future.then((_) {
            if (!handler.isCompleted) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: const [
                    {
                      'id': 2,
                      'user1_id': 2,
                      'user2_id': 9,
                      'last_message_at': '2026-08-24T00:00:00Z',
                      'unread_count': 4,
                    },
                  ],
                ),
              );
            }
          });
        },
      ),
    );
    final provider = MessageProvider(dio, enableRealtime: false);
    addTearDown(provider.dispose);

    provider.syncSessionUser(1, 1);
    final staleLoad = provider.loadConversations();
    await firstStarted.future;

    provider.syncSessionUser(2, 2);
    final currentLoad = provider.loadConversations();
    await secondStarted.future;
    firstGate.complete();
    await staleLoad;

    expect(provider.conversationLoading, isTrue);
    expect(provider.conversationError, isNull);
    expect(provider.conversations, isEmpty);
    expect(provider.hasLoadedConversations, isFalse);

    secondGate.complete();
    await currentLoad;

    expect(provider.conversationLoading, isFalse);
    expect(provider.conversationError, isNull);
    expect(provider.conversations.single.id, 2);
    expect(provider.unreadMessageCount, 4);
  });

  test('账号切换会取消在途发送且旧回包不会写入新会话', () async {
    final dio = Dio();
    final requestStarted = Completer<void>();
    final responseGate = Completer<void>();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'POST' && options.path == '/messages/3') {
            final data = Map<String, dynamic>.from(options.data as Map);
            requestStarted.complete();
            responseGate.future.then((_) {
              if (!handler.isCompleted) {
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 201,
                    data: _messageJson(
                      id: 900,
                      clientMessageId: data['client_message_id'] as String,
                    ),
                  ),
                );
              }
            });
            return;
          }
          handler.reject(_unexpectedRequest(options));
        },
      ),
    );
    final provider = MessageProvider(dio, enableRealtime: false);
    addTearDown(provider.dispose);

    provider.syncSessionUser(1, 1);
    final send = provider.sendMessage(3, 'A 的消息', senderId: 1);
    await requestStarted.future;
    expect(provider.messages.single.isPending, isTrue);

    provider.syncSessionUser(2, 2);
    responseGate.complete();

    expect(await send, isNull);
    expect(provider.messages, isEmpty);
    expect(provider.conversations, isEmpty);
    expect(provider.currentConversationId, isNull);
    expect(provider.messageError, isNull);
  });
}

Map<String, dynamic> _messageJson({
  required int id,
  required String clientMessageId,
  String content = 'hello',
}) {
  return {
    'id': id,
    'conversation_id': 42,
    'sender_id': 8,
    'client_message_id': clientMessageId,
    'content': content,
    'created_at': '2026-06-14T08:14:00Z',
  };
}

DioException _unexpectedRequest(RequestOptions options) {
  return DioException(
    requestOptions: options,
    message: 'Unexpected request: ${options.method} ${options.path}',
  );
}
