import 'dart:convert';

import 'package:shenliyuan/utils/private_message_notification.dart';

const nativeNotificationOpenIdKey = '_native_notification_open_id';

class NativeNotificationOpen {
  const NativeNotificationOpen({
    required this.id,
    required this.payload,
    required this.openedAt,
  });

  final String id;
  final Map<String, dynamic> payload;
  final DateTime openedAt;

  bool isExpired(
    DateTime now, {
    Duration ttl = const Duration(hours: 24),
  }) {
    return now.difference(openedAt) > ttl;
  }

  static NativeNotificationOpen? parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      final id = decoded['id']?.toString().trim() ?? '';
      final payloadValue = decoded['payload'];
      final openedAtMillis = intFromNotificationExtra(decoded['opened_at']);
      if (id.isEmpty || payloadValue is! Map || openedAtMillis == null) {
        return null;
      }

      return NativeNotificationOpen(
        id: id,
        payload: payloadValue.map(
          (key, value) => MapEntry(key.toString(), value),
        ),
        openedAt: DateTime.fromMillisecondsSinceEpoch(openedAtMillis),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> payloadWithTrackingId() => {
        ...payload,
        nativeNotificationOpenIdKey: id,
      };
}

enum NotificationOpenType {
  reply,
}

class NotificationOpenTarget {
  const NotificationOpenTarget({
    required this.type,
    required this.createdAt,
    this.postId,
    this.replyId,
    this.nativeOpenId,
  });

  final NotificationOpenType type;
  final int? postId;
  final int? replyId;
  final String? nativeOpenId;
  final DateTime createdAt;

  bool isExpired(
    DateTime now, {
    Duration ttl = const Duration(seconds: 30),
  }) {
    return now.difference(createdAt) > ttl;
  }

  bool hasSameDestination(NotificationOpenTarget other) {
    return type == other.type &&
        postId == other.postId &&
        replyId == other.replyId;
  }

  static NotificationOpenTarget? parse(
    Map<dynamic, dynamic> message, {
    DateTime? now,
  }) {
    final stringMessage =
        message.map((key, value) => MapEntry(key.toString(), value));
    final extras = extractJPushExtras(stringMessage);
    final type = extras['type']?.toString().trim().toLowerCase();

    final postId = _positiveId(
      extras['post_id'] ?? extras['postId'],
    );
    final replyId = _positiveId(
      extras['reply_id'] ?? extras['replyId'],
    );

    switch (type) {
      case 'reply':
        return NotificationOpenTarget(
          type: NotificationOpenType.reply,
          postId: postId,
          replyId: replyId,
          nativeOpenId: extras[nativeNotificationOpenIdKey]?.toString(),
          createdAt: now ?? DateTime.now(),
        );

      default:
        return null;
    }
  }

  static int? _positiveId(dynamic value) {
    final parsed = intFromNotificationExtra(value);
    return parsed != null && parsed > 0 ? parsed : null;
  }
}

class PendingNotificationOpen {
  PendingNotificationOpen({
    this.ttl = const Duration(seconds: 30),
  });

  final Duration ttl;
  NotificationOpenTarget? _target;

  NotificationOpenTarget? get target => _target;

  void store(NotificationOpenTarget target) {
    _target = target;
  }

  NotificationOpenTarget? consume(DateTime now) {
    final target = _target;
    if (target == null) return null;

    _target = null;

    if (target.isExpired(now, ttl: ttl)) {
      return null;
    }

    return target;
  }

  void clear() {
    _target = null;
  }
}
