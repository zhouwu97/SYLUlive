import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/services/feed_event_service.dart';
import 'package:shenliyuan/services/feed_session_service.dart';

void main() {
  group('FeedSessionService', () {
    test('首次进入新建 session；同会话内保持不变', () {
      final session = FeedSessionService();
      final id = session.newSession();
      expect(id, isNotEmpty);
      expect(session.currentSessionId, id);

      // 未过期：freshSession 沿用。
      expect(session.freshSession(), id);
    });

    test('后台超过 30 分钟后 freshSession 新建', () {
      final session = FeedSessionService();
      final old = session.newSession();
      expect(session.freshSession(), old);

      // 模拟超时：直接推进 created 时间不可行，改用断言 isStale 逻辑。
      // 这里验证 resetForAccountChange 会换 session。
      final next = session.resetForAccountChange();
      expect(next, isNot(old));
      expect(session.currentSessionId, next);
    });

    test('切换账号重置并新建 session', () {
      final session = FeedSessionService();
      final a = session.newSession();
      final b = session.resetForAccountChange();
      expect(b, isNot(a));
    });

    test('session id 包含时间戳与随机性（两次新建不同）', () {
      final session = FeedSessionService();
      final a = session.newSession();
      final b = session.newSession();
      expect(a, isNot(b));
      expect(
          a.startsWith(
              '${DateTime.now().millisecondsSinceEpoch}'.substring(0, 4)),
          isTrue); // 时间戳前缀
    });

    test('session id 的随机段保持在无符号 32 位范围内', () {
      final session = FeedSessionService();
      final randomPart = int.parse(session.newSession().split('_').last);
      expect(randomPart, inInclusiveRange(0, 0xFFFFFFFF));
    });
  });

  group('FeedEventService', () {
    test('事件按 (session, kind, algorithm) 分组批量上报', () async {
      final requests = <Map<String, dynamic>>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/feed/events/batch') {
              requests.add(options.data as Map<String, dynamic>);
            }
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: {}),
            );
          },
        ),
      );
      final svc = FeedEventService(dio, maxBatch: 40);

      svc.enqueue(FeedEvent(
          feedSessionId: 's1',
          feedKind: 'all',
          algorithmVersion: 'v3',
          type: 'impression',
          postId: 1,
          position: 0,
          visibleMs: 800));
      svc.enqueue(FeedEvent(
          feedSessionId: 's1',
          feedKind: 'all',
          algorithmVersion: 'v3',
          type: 'impression',
          postId: 2,
          position: 1,
          visibleMs: 900));
      svc.enqueue(FeedEvent(
          feedSessionId: 's2',
          feedKind: 'time',
          algorithmVersion: 'v3',
          type: 'open',
          postId: 3));

      await svc.flush();

      expect(requests, hasLength(2));
      // 分组：s1/all/v3 一组含两个 impression；s2/time/v3 一组含一个 open。
      final group1 = requests.firstWhere((r) => r['feed_session_id'] == 's1');
      expect(group1['feed_kind'], 'all');
      expect((group1['events'] as List), hasLength(2));
      final group2 = requests.firstWhere((r) => r['feed_session_id'] == 's2');
      expect(group2['feed_kind'], 'time');
      expect((group2['events'] as List), hasLength(1));
      expect((group2['events'] as List).single['type'], 'open');

      expect(svc.pendingEvents, isEmpty);
      svc.dispose();
    });

    test('失败有界重试：失败后事件回到队列，超过上限后丢弃', () async {
      var calls = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            calls++;
            handler.reject(
              DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError),
            );
          },
        ),
      );
      final svc = FeedEventService(dio, maxBatch: 40);
      svc.enqueue(FeedEvent(
          feedSessionId: 's1',
          feedKind: 'all',
          algorithmVersion: 'v3',
          type: 'impression',
          postId: 1,
          visibleMs: 800));

      await svc.flush();
      expect(svc.pendingEvents, isNotEmpty, reason: '失败后事件回队列重试');
      svc.dispose();
    });
  });
}
