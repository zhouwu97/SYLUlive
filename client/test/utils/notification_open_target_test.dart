import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/notification_open_target.dart';

void main() {
  group('NativeNotificationOpen', () {
    test('解析原生持久化事件并把追踪 ID 注入 payload', () {
      final event = NativeNotificationOpen.parse(jsonEncode({
        'id': 'open-123',
        'opened_at': 1785859200000,
        'payload': {
          'type': 'reply',
          'post_id': 12,
          'reply_id': 34,
        },
      }));

      expect(event, isNotNull);
      expect(event!.id, 'open-123');
      expect(event.payload['post_id'], 12);
      expect(
        event.payloadWithTrackingId()[nativeNotificationOpenIdKey],
        'open-123',
      );
      expect(
        event.isExpired(
          event.openedAt.add(const Duration(hours: 23)),
        ),
        isFalse,
      );
      expect(
        event.isExpired(
          event.openedAt.add(const Duration(hours: 25)),
        ),
        isTrue,
      );
    });

    test('拒绝缺少事件 ID 或 payload 的数据', () {
      expect(
        NativeNotificationOpen.parse(
          jsonEncode({'opened_at': 1785859200000, 'payload': {}}),
        ),
        isNull,
      );
      expect(
        NativeNotificationOpen.parse(
          jsonEncode({'id': 'open-123', 'opened_at': 1785859200000}),
        ),
        isNull,
      );
    });
  });

  group('NotificationOpenTarget Parse', () {
    test('应该能解析 reply 类型的基本通知', () {
      final message = {
        'extras': {
          'type': 'reply',
          'post_id': 123,
          'reply_id': 456,
          notificationRecipientUserIdKey: 7,
        }
      };

      final target = NotificationOpenTarget.parse(message);

      expect(target, isNotNull);
      expect(target!.type, NotificationOpenType.reply);
      expect(target.postId, 123);
      expect(target.replyId, 456);
      expect(target.recipientUserId, 7);
    });

    test('保留原生事件 ID 供导航成功后确认', () {
      final target = NotificationOpenTarget.parse({
        'type': 'reply',
        'post_id': 123,
        nativeNotificationOpenIdKey: 'open-456',
      });

      expect(target?.nativeOpenId, 'open-456');
    });

    test('忽略未知或缺少关键信息的通知', () {
      final message = {
        'extras': {
          'type': 'unknown_type',
        }
      };
      final target = NotificationOpenTarget.parse(message);
      expect(target, isNull);
    });

    test('应该忽略已停用的集市广播通知', () {
      final message = {
        'extras': {
          'type': 'market_post',
          'post_id': 123,
        }
      };

      expect(NotificationOpenTarget.parse(message), isNull);
    });

    test('相同目标的判断机制正确 (hasSameDestination)', () {
      final t1 = NotificationOpenTarget(
        type: NotificationOpenType.reply,
        postId: 1,
        replyId: 2,
        createdAt: DateTime(2026),
      );

      final t2 = NotificationOpenTarget(
        type: NotificationOpenType.reply,
        postId: 1,
        replyId: 2,
        createdAt: DateTime(2027), // 时间不同不影响
      );

      final t3 = NotificationOpenTarget(
        type: NotificationOpenType.reply,
        postId: 1,
        replyId: 3,
        createdAt: DateTime(2026),
      );

      expect(t1.hasSameDestination(t2), isTrue);
      expect(t1.hasSameDestination(t3), isFalse);
    });
  });

  group('notificationAccountDecision', () {
    test('认证未完成时等待，不提前消费通知', () {
      expect(
        notificationAccountDecision(
          authInitialized: false,
          currentUserId: null,
          recipientUserId: 7,
        ),
        NotificationAccountDecision.waitForAuthentication,
      );
    });

    test('仅允许当前登录账号消费归属匹配的通知', () {
      expect(
        notificationAccountDecision(
          authInitialized: true,
          currentUserId: 7,
          recipientUserId: 7,
        ),
        NotificationAccountDecision.allow,
      );
      expect(
        notificationAccountDecision(
          authInitialized: true,
          currentUserId: 8,
          recipientUserId: 7,
        ),
        NotificationAccountDecision.reject,
      );
      expect(
        notificationAccountDecision(
          authInitialized: true,
          currentUserId: 7,
          recipientUserId: null,
        ),
        NotificationAccountDecision.reject,
      );
    });
  });
}
