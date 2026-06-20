import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/utils/private_message_notification.dart';

void main() {
  group('privateMessageTargetFromJPushMessage', () {
    test('parses nested JPush extras json string', () {
      final target = privateMessageTargetFromJPushMessage({
        'title': 'Alice fallback',
        'extras': {
          'cn.jpush.android.EXTRA': jsonEncode({
            'type': 'private_message',
            'conversation_id': '12',
            'sender_id': '7',
            'sender_name': 'Alice',
          }),
        },
      });

      expect(target?.conversationId, 12);
      expect(target?.senderId, 7);
      expect(target?.senderName, 'Alice');
      expect(target?.displayName, 'Alice');
    });

    test('parses top-level JPush extras json string', () {
      final target = privateMessageTargetFromJPushMessage({
        'cn.jpush.android.EXTRA': jsonEncode({
          'type': 'private_message',
          'conversation_id': 23,
          'sender_id': 9,
        }),
        'notificationTitle': 'Bob',
      });

      expect(target?.conversationId, 23);
      expect(target?.senderId, 9);
      expect(target?.senderName, 'Bob');
    });

    test('falls back to generated user name when sender name is missing', () {
      final target = privateMessageTargetFromJPushMessage({
        'extras': {
          'type': 'private_message',
          'conversation_id': '5',
          'sender_id': '88',
        },
      });

      expect(target?.displayName, '用户88');
    });
  });

  test('privateMessageTargetFromLocalPayload parses click payload', () {
    final target = privateMessageTargetFromLocalPayload(jsonEncode({
      'conversation_id': '31',
      'sender_id': '11',
      'sender_name': 'Carol',
    }));

    expect(target?.conversationId, 31);
    expect(target?.senderId, 11);
    expect(target?.displayName, 'Carol');
  });

  group('PendingPrivateMessageOpen', () {
    test('keeps only the latest pending target', () {
      final pending = PendingPrivateMessageOpen();
      const first = PrivateMessageTarget(
        conversationId: 1,
        senderId: 2,
        senderName: 'First',
      );
      const second = PrivateMessageTarget(
        conversationId: 3,
        senderId: 4,
        senderName: 'Second',
      );

      final now = DateTime(2026, 6, 20, 12);
      pending.store(first);
      pending.store(second);
      pending.markReady(now);

      expect(pending.consume(now.add(const Duration(seconds: 1))), second);
      expect(pending.target, isNull);
    });

    test('drops stale target after it has been ready longer than ttl', () {
      final pending = PendingPrivateMessageOpen(
        ttl: const Duration(seconds: 10),
      );
      const target = PrivateMessageTarget(
        conversationId: 1,
        senderId: 2,
        senderName: 'Alice',
      );

      final now = DateTime(2026, 6, 20, 12);
      pending.store(target);
      pending.markReady(now);

      expect(pending.consume(now.add(const Duration(seconds: 11))), isNull);
      expect(pending.target, isNull);
    });
  });
}
