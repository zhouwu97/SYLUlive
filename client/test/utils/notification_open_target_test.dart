import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/notification_open_target.dart';

void main() {
  group('NotificationOpenTarget Parse', () {
    test('应该能解析 reply 类型的基本通知', () {
      final message = {
        'extras': {
          'type': 'reply',
          'post_id': 123,
          'reply_id': 456,
        }
      };
      
      final target = NotificationOpenTarget.parse(message);
      
      expect(target, isNotNull);
      expect(target!.type, NotificationOpenType.reply);
      expect(target.postId, 123);
      expect(target.replyId, 456);
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
}
