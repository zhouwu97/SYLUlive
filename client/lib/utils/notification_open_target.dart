import 'package:shenliyuan/utils/private_message_notification.dart';

enum NotificationOpenType {
  reply,
  marketPost,
}

class NotificationOpenTarget {
  const NotificationOpenTarget({
    required this.type,
    required this.createdAt,
    this.postId,
    this.replyId,
  });

  final NotificationOpenType type;
  final int? postId;
  final int? replyId;
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
    final stringMessage = message.map((key, value) => MapEntry(key.toString(), value));
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
          createdAt: now ?? DateTime.now(),
        );

      case 'market_post':
        if (postId == null) return null;
        return NotificationOpenTarget(
          type: NotificationOpenType.marketPost,
          postId: postId,
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
