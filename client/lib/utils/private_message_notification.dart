import 'dart:convert';

class PrivateMessageTarget {
  final int conversationId;
  final int senderId;
  final String senderName;
  final String senderAvatar;
  final int? messageId;

  const PrivateMessageTarget({
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    this.senderAvatar = '',
    this.messageId,
  });

  String get displayName {
    final trimmed = senderName.trim();
    return trimmed.isEmpty ? '用户$senderId' : trimmed;
  }

  bool sameConversation(PrivateMessageTarget other) {
    return conversationId == other.conversationId && senderId == other.senderId;
  }

  PrivateMessageTarget copyWith({String? senderName, String? senderAvatar}) {
    return PrivateMessageTarget(
      conversationId: conversationId,
      senderId: senderId,
      senderName: senderName ?? this.senderName,
      senderAvatar: senderAvatar ?? this.senderAvatar,
      messageId: messageId,
    );
  }
}

class PendingPrivateMessageOpen {
  PendingPrivateMessageOpen({this.ttl = const Duration(seconds: 10)});

  final Duration ttl;
  PrivateMessageTarget? _target;
  DateTime? _readyAt;

  PrivateMessageTarget? get target => _target;

  void store(PrivateMessageTarget target) {
    _target = target;
    _readyAt = null;
  }

  void markReady(DateTime now) {
    if (_target == null || _readyAt != null) return;
    _readyAt = now;
  }

  PrivateMessageTarget? consume(DateTime now) {
    final target = _target;
    if (target == null) return null;
    final readyAt = _readyAt;
    if (readyAt != null && now.difference(readyAt) > ttl) {
      clear();
      return null;
    }
    clear();
    return target;
  }

  void clear() {
    _target = null;
    _readyAt = null;
  }
}

PrivateMessageTarget? privateMessageTargetFromJPushMessage(
  Map<String, dynamic> message,
) {
  final extras = extractJPushExtras(message);
  if (extras['type']?.toString() != 'private_message') return null;

  final conversationId = intFromNotificationExtra(extras['conversation_id']);
  final senderId = intFromNotificationExtra(extras['sender_id']);
  final messageId = intFromNotificationExtra(extras['message_id']);
  if (conversationId == null || senderId == null) return null;

  final senderName = _firstNonEmpty([
    extras['sender_name']?.toString(),
    notificationTitle(message),
    '用户$senderId',
  ]);
  final senderAvatar = _firstNonEmpty([
    extras['sender_avatar']?.toString(),
    extras['avatar']?.toString(),
  ]);

  return PrivateMessageTarget(
    conversationId: conversationId,
    senderId: senderId,
    senderName: senderName,
    senderAvatar: senderAvatar,
    messageId: messageId,
  );
}

PrivateMessageTarget? privateMessageTargetFromLocalPayload(String payload) {
  if (payload.isEmpty) return null;
  final decoded = jsonDecode(payload);
  if (decoded is! Map) return null;
  final extras = decoded.map((key, value) => MapEntry(key.toString(), value));
  final conversationId = intFromNotificationExtra(extras['conversation_id']);
  final senderId = intFromNotificationExtra(extras['sender_id']);
  final messageId = intFromNotificationExtra(extras['message_id']);
  if (conversationId == null || senderId == null) return null;
  final senderName = _firstNonEmpty([
    extras['sender_name']?.toString(),
    '用户$senderId',
  ]);
  final senderAvatar = _firstNonEmpty([
    extras['sender_avatar']?.toString(),
    extras['avatar']?.toString(),
  ]);
  return PrivateMessageTarget(
    conversationId: conversationId,
    senderId: senderId,
    senderName: senderName,
    senderAvatar: senderAvatar,
    messageId: messageId,
  );
}

int? intFromNotificationExtra(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

String notificationTitle(Map<String, dynamic> message) {
  return _firstNonEmpty([
    message['title']?.toString(),
    message['notificationTitle']?.toString(),
    _androidNotificationValue(message, 'title'),
  ]);
}

String notificationContent(Map<String, dynamic> message) {
  return _firstNonEmpty([
    message['alert']?.toString(),
    message['content']?.toString(),
    message['message']?.toString(),
    _androidNotificationValue(message, 'alert'),
  ]);
}

String? _androidNotificationValue(Map<String, dynamic> message, String key) {
  final android = message['android'];
  if (android is Map && android[key] != null) {
    return android[key].toString();
  }
  return null;
}

Map<String, dynamic> extractJPushExtras(Map<String, dynamic> message) {
  final extras = message['extras'];
  if (extras is Map) {
    final inner = extras['cn.jpush.android.EXTRA'];
    if (inner is Map) {
      return inner.map((key, value) => MapEntry(key.toString(), value));
    }
    if (inner is String) {
      final decoded = _decodeJsonMap(inner);
      if (decoded != null) return decoded;
    }
    return extras.map((key, value) => MapEntry(key.toString(), value));
  }

  final android = message['android'];
  if (android is Map && android['extras'] is Map) {
    final androidExtras = android['extras'] as Map;
    return androidExtras.map((key, value) => MapEntry(key.toString(), value));
  }

  final rawExtra = message['cn.jpush.android.EXTRA'];
  if (rawExtra is Map) {
    return rawExtra.map((key, value) => MapEntry(key.toString(), value));
  }
  if (rawExtra is String) {
    final decoded = _decodeJsonMap(rawExtra);
    if (decoded != null) return decoded;
  }

  return message.map((key, value) => MapEntry(key.toString(), value));
}

Map<String, dynamic>? _decodeJsonMap(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {}
  return null;
}

String _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}
