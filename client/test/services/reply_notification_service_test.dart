import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/reply_notification_service.dart';

void main() {
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
}
