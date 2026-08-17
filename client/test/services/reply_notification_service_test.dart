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
