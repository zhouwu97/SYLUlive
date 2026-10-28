import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shenliyuan/services/reply_notification_service.dart';
import 'package:shenliyuan/services/publish_session_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('旧服务无回执时，只同步当前账号已成功读取的单条通知', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('shenliyuan/notification_open');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
          onRequest: (o, h) => h.resolve(Response(
              requestOptions: o, statusCode: 200, data: {'updated': 1}))));
    await ReplyNotificationService(dio, recipientUserId: 7)
        .markRead(11, replyId: 13);
    expect(calls.single.arguments, {
      'recipient_user_id': 7,
      'ids': [11],
      'reply_ids': [13]
    });
  });

  test('旧服务拒绝帖子回复条件时，翻页精确匹配通知 ID 再同步系统', () async {
    final calls = <MethodCall>[];
    final writes = <Object?>[];
    const channel = MethodChannel('shenliyuan/notification_open');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.method == 'POST') {
          writes.add(o.data);
          if ((o.data as Map).containsKey('post_id')) {
            h.reject(DioException(
                requestOptions: o,
                response: Response(
                    requestOptions: o,
                    statusCode: 400,
                    data: {'error': 'ids不能为空'})));
          } else {
            h.resolve(Response(
                requestOptions: o, statusCode: 200, data: {'updated': 1}));
          }
        } else {
          final second = o.queryParameters['cursor'] == 'next';
          h.resolve(Response(requestOptions: o, statusCode: 200, data: {
            'items': second
                ? [
                    {
                      'id': '11',
                      'type': 'reply',
                      'post_id': 20,
                      'related_id': 13
                    }
                  ]
                : [
                    {
                      'id': 99,
                      'type': 'reply',
                      'post_id': 21,
                      'related_id': 13
                    },
                    {'id': 98, 'type': 'reply', 'post_id': 20, 'related_id': 14}
                  ],
            'next_cursor': second ? '' : 'next',
          }));
        }
      }));
    await ReplyNotificationService(dio, recipientUserId: 7)
        .markReplyRead(postId: 20, replyId: 13);
    expect(writes, [
      {'post_id': 20, 'reply_id': 13},
      {
        'ids': [11]
      }
    ]);
    expect(calls.single.arguments, {
      'recipient_user_id': 7,
      'ids': [11],
      'reply_ids': [13]
    });
  });

  test('旧服务写入失败或目标不存在时保留系统通知', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('shenliyuan/notification_open');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.method == 'POST') {
          h.reject(DioException(
              requestOptions: o,
              response: Response(requestOptions: o, statusCode: 400)));
        } else {
          h.resolve(Response(
              requestOptions: o,
              statusCode: 200,
              data: {'items': [], 'next_cursor': ''}));
        }
      }));
    await expectLater(
        ReplyNotificationService(dio, recipientUserId: 7)
            .markReplyRead(postId: 20, replyId: 13),
        throwsStateError);
    expect(calls, isEmpty);
  });

  test('账号切换后的旧请求不得继续反查或清除系统通知', () async {
    var current = true;
    var reads = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.method == 'GET') reads++;
        current = false;
        h.reject(DioException(
            requestOptions: o,
            response: Response(requestOptions: o, statusCode: 400)));
      }));
    await expectLater(
        ReplyNotificationService(dio,
                recipientUserId: 7, isCurrentSession: () => current)
            .markReplyRead(postId: 20, replyId: 13),
        throwsStateError);
    expect(reads, 0);
  });

  test('已读回执属于其他账号时不清理原生通知', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('shenliyuan/notification_open');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
          onRequest: (o, h) =>
              h.resolve(Response(requestOptions: o, statusCode: 200, data: {
                'read_receipt': {
                  'recipient_user_id': 8,
                  'ids': [11]
                }
              }))));
    await ReplyNotificationService(dio, recipientUserId: 7).markRead(11);
    expect(calls, isEmpty);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  test('定位回复后只消费对应帖子和回复的通知', () async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      expect(options.path, '/notifications/read-selected');
      expect(options.data, {'post_id': 100, 'reply_id': 11});
      handler.resolve(Response(requestOptions: options, statusCode: 200));
    }));
    await ReplyNotificationService(dio).markReplyRead(postId: 100, replyId: 11);
  });
  test('已读回执成功后同步原生；失败请求不清系统提醒', () async {
    const channel = MethodChannel('shenliyuan/notification_open');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    var status = 200;
    final dio = Dio(BaseOptions(validateStatus: (_) => true));
    final receipt = {
      'recipient_user_id': 7,
      'ids': [11],
      'reply_ids': [13]
    };
    dio.interceptors.add(InterceptorsWrapper(
        onRequest: (o, h) => h.resolve(Response(
            requestOptions: o,
            statusCode: status,
            data: {'read_receipt': receipt}))));
    await ReplyNotificationService(dio).markRead(11);
    expect(calls.single.method, 'syncNotificationRead');
    expect(calls.single.arguments, receipt);
    status = 500;
    await expectLater(
        ReplyNotificationService(dio).markRead(11), throwsStateError);
    expect(calls, hasLength(1));
  });
  test('查询未读回复摘要并映射帖子标题', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.path, '/notifications/replies/unread');
        expect(options.queryParameters['limit'], 20);
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'count': 2,
              'items': [
                {
                  'id': 11,
                  'post_id': 100,
                  'related_id': 502,
                  'content': '最新回复',
                  'post_title': '我的水帖',
                  'created_at': '2026-08-18T10:01:00Z',
                  'from_user': {
                    'id': 3,
                    'nickname': '回复者B',
                    'avatar': '',
                  },
                },
              ],
            },
          ),
        );
      }),
    );

    final result = await ReplyNotificationService(dio).fetchUnread();

    expect(result.count, 2);
    expect(result.items.single.postTitle, '我的水帖');
    expect(result.items.single.fromUser?.nickname, '回复者B');
  });

  test('新接口不存在时回退旧通知列表并筛出未读回复', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/notifications/replies/unread') {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 404,
              ),
            ),
          );
          return;
        }
        if (options.path == '/posts/110') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'id': 110, 'title': '旧接口帖子标题'},
            ),
          );
          return;
        }
        expect(options.path, '/notifications');
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: [
              {
                'id': 21,
                'type': 'reply',
                'is_read': false,
                'post_id': 110,
                'related_id': 610,
                'content': '旧接口里的未读回复',
                'created_at': '2026-08-18T11:00:00Z',
                'from_user': {
                  'id': 4,
                  'nickname': '旧回复者',
                  'avatar': '',
                },
              },
              {
                'id': 24,
                'type': 'reply',
                'is_read': false,
                'post_id': 112,
                'related_id': 612,
                'content': '第二条旧接口未读回复',
                'created_at': '2026-08-18T10:30:00Z',
              },
              {
                'id': 22,
                'type': 'reply',
                'is_read': true,
                'post_id': 111,
                'related_id': 611,
                'content': '已读回复',
                'created_at': '2026-08-18T10:00:00Z',
              },
              {
                'id': 23,
                'type': 'announcement',
                'is_read': false,
                'post_id': 0,
                'related_id': 0,
                'content': '其它通知',
                'created_at': '2026-08-18T09:00:00Z',
              },
            ],
          ),
        );
      }),
    );

    final result = await ReplyNotificationService(dio).fetchUnread(limit: 1);

    expect(result.count, 2);
    expect(result.items.single.id, 21);
    expect(result.items.single.postId, 110);
    expect(result.items.single.postTitle, '旧接口帖子标题');
    expect(result.items.single.fromUser?.nickname, '旧回复者');
  });

  test('单条已读只提交选中的通知 ID', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.path, '/notifications/read-selected');
        expect(options.data, {
          'ids': [11]
        });
        handler.resolve(Response(requestOptions: options, statusCode: 200));
      }),
    );

    await ReplyNotificationService(dio).markRead(11);
  });

  test('全部已读请求成功后正常返回', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.path, '/notifications/read');
        handler.resolve(Response(requestOptions: options, statusCode: 200));
      }),
    );

    await ReplyNotificationService(dio).markAllRead();
  });

  test('互动弹层一键已读仅标记回复，包含未加载的回复', () async {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(onRequest: (options, handler) {
        expect(options.path, '/notifications/replies/read');
        expect(options.queryParameters, isEmpty);
        expect(options.data, isNull);
        handler.resolve(Response(requestOptions: options, statusCode: 200));
      }),
    );
    await ReplyNotificationService(dio).markAllRead(repliesOnly: true);
  });

  test('已读写请求携带发起会话，旧服务端 404 不降级为全部已读', () async {
    final dio = Dio();
    final paths = <String>[];
    const session = PublishSessionScope(accountId: 1, accountSessionEpoch: 7);
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      paths.add(options.path);
      expect(options.extra, containsPair('expectedAuthUserId', 1));
      expect(options.extra, containsPair('expectedAuthSessionEpoch', 7));
      handler.reject(DioException(
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 404)));
    }));
    await expectLater(
        ReplyNotificationService(dio)
            .markAllRead(repliesOnly: true, session: session),
        throwsA(isA<DioException>()));
    expect(paths, ['/notifications/replies/read']);
    paths.clear();
    await expectLater(
        ReplyNotificationService(dio).markRead(11, session: session),
        throwsA(isA<DioException>()));
    expect(paths, ['/notifications/read-selected']);
  });

  test('已读接口返回非 2xx 时抛出错误', () async {
    final dio = Dio(BaseOptions(validateStatus: (_) => true));
    dio.interceptors.add(
      InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(Response(requestOptions: options, statusCode: 500));
      }),
    );

    expect(
      ReplyNotificationService(dio).markRead(11),
      throwsA(isA<StateError>()),
    );
  });
}
