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
    try {
      final response = await _dio.get(
        '/notifications/replies/unread',
        queryParameters: {'limit': safeLimit},
      );
      final data = response.data;
      if (response.statusCode != 200 || data is! Map<String, dynamic>) {
        throw StateError('未读回复响应格式错误');
      }
      final page = UnreadReplyNotificationPage.fromJson(data);
      return UnreadReplyNotificationPage(
        count: page.count,
        items: await _hydratePostTitles(page.items),
      );
    } on DioException catch (error) {
      // 旧版服务端没有首页专用接口时，从已有通知列表兼容读取。
      if (error.response?.statusCode != 404) rethrow;
      return _fetchLegacyUnread(safeLimit);
    }
  }

  Future<UnreadReplyNotificationPage> _fetchLegacyUnread(int limit) async {
    final response = await _dio.get('/notifications');
    final data = response.data;
    if (response.statusCode != 200 || data is! List) {
      throw StateError('旧版通知响应格式错误');
    }

    final unreadReplies = data
        .whereType<Map<String, dynamic>>()
        .where((item) => item['type'] == 'reply' && item['is_read'] == false)
        .toList(growable: false);
    final items = unreadReplies
        .take(limit)
        .map(UnreadReplyNotification.fromJson)
        .toList(growable: false);

    return UnreadReplyNotificationPage(
      count: unreadReplies.length,
      items: await _hydratePostTitles(items),
    );
  }

  Future<List<UnreadReplyNotification>> _hydratePostTitles(
    List<UnreadReplyNotification> items,
  ) async {
    final postTitles = <int, String>{};
    final missingPostIds = items
        .where((item) => item.postTitle.trim().isEmpty && item.postId > 0)
        .map((item) => item.postId)
        .toSet();
    await Future.wait(
      missingPostIds.map((postId) async {
        try {
          final postResponse = await _dio.get('/posts/$postId');
          if (postResponse.statusCode != 200 ||
              postResponse.data is! Map<String, dynamic>) {
            return;
          }
          final postData = postResponse.data as Map<String, dynamic>;
          final title = postData['title']?.toString().trim() ?? '';
          if (title.isNotEmpty) postTitles[postId] = title;
        } on DioException {
          // 单个帖子获取失败不应阻断其他未读回复展示。
        }
      }),
    );

    return items
        .map((item) => item.copyWith(postTitle: postTitles[item.postId]))
        .toList(growable: false);
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
