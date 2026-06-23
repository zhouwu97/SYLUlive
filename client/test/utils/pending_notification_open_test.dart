import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/notification_open_target.dart';

void main() {
  group('PendingNotificationOpen', () {
    test('应该能成功存入并取出目标', () {
      final pending = PendingNotificationOpen();
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      
      final target = NotificationOpenTarget(
        type: NotificationOpenType.reply,
        postId: 1,
        createdAt: now,
      );

      pending.store(target);
      final consumed = pending.consume(now.add(const Duration(seconds: 5)));

      expect(consumed, isNotNull);
      expect(consumed!.type, NotificationOpenType.reply);
      // 一旦消费，就不应该再被取出
      expect(pending.consume(now.add(const Duration(seconds: 5))), isNull);
    });

    test('超过 TTL 应该返回 null 并丢弃', () {
      final pending = PendingNotificationOpen(ttl: const Duration(seconds: 30));
      final now = DateTime(2026, 1, 1, 12, 0, 0);
      
      final target = NotificationOpenTarget(
        type: NotificationOpenType.marketPost,
        postId: 1,
        createdAt: now,
      );

      pending.store(target);
      // 等待超过 30 秒 (过了 TTL)
      final consumed = pending.consume(now.add(const Duration(seconds: 31)));

      expect(consumed, isNull);
    });
  });
}
