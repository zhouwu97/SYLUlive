import 'package:dio/dio.dart';
import 'package:shenliyuan/models/unread_reply_notification.dart';

class UnreadReplyNotificationPage {
  final int count;
  final List<UnreadReplyNotification> items;

  const UnreadReplyNotificationPage({
    required this.count,
    required this.items,
  });

  factory UnreadReplyNotificationPage.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(UnreadReplyNotification.fromJson)
        .toList(growable: false);
    return UnreadReplyNotificationPage(
      count: (json['count'] as num?)?.toInt() ?? rawItems.length,
      items: rawItems,
    );
  }
}

class ReplyNotificationService {
  final Dio _dio;

  const ReplyNotificationService(this._dio);

  Future<UnreadReplyNotificationPage> fetchUnread({int limit = 20}) async {
    final safeLimit = limit.clamp(1, 20).toInt();
    final response = await _dio.get(
      '/notifications/replies/unread',
      queryParameters: {'limit': safeLimit},
    );
    final data = response.data;
    if (response.statusCode != 200 || data is! Map<String, dynamic>) {
      throw StateError('未读回复响应格式错误');
    }
    return UnreadReplyNotificationPage.fromJson(data);
  }

  Future<void> markRead(int notificationId) async {
    await _dio.post(
      '/notifications/read-selected',
      data: {
        'ids': [notificationId]
      },
    );
  }
}
