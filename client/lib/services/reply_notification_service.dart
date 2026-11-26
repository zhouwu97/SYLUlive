import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:shenliyuan/models/unread_reply_notification.dart';
import 'publish_session_scope.dart';

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
  static final _pendingSystemReads = <int, List<Map<String, dynamic>>>{};

  final Dio _dio;
  final int? recipientUserId;
  final bool Function()? isCurrentSession;

  const ReplyNotificationService(this._dio,
      {this.recipientUserId, this.isCurrentSession});

  void _checkSession() {
    if (isCurrentSession?.call() == false) {
      throw StateError('通知所属账号已切换');
    }
  }

  Future<UnreadReplyNotificationPage> fetchUnread({int limit = 20}) async {
    await _retrySystemReads();
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
    final rawItems = data is List
        ? data
        : data is Map
            ? data['items']
            : null;
    if (response.statusCode != 200 || rawItems is! List) {
      throw StateError('旧版通知响应格式错误');
    }

    final unreadReplies = rawItems
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

  Future<Map<int, List<int>>> fetchPostUnread(int postId) async {
    _checkSession();
    await _retrySystemReads();
    final response = await _dio.get('/posts/$postId/notifications/unread');
    _checkSession();
    final items = response.data['items'] as List;
    final result = <int, List<int>>{};
    for (final item in items.whereType<Map>()) {
      final id = _id(item['id']);
      final reply = _id(item['related_id']);
      if (_id(item['post_id']) == postId &&
          id != null &&
          id > 0 &&
          reply != null &&
          reply > 0) {
        (result[reply] ??= []).add(id);
      }
    }
    return result;
  }

  Future<void> markRead(int notificationId,
      {int? replyId, PublishSessionScope? session}) async {
    _checkSession();
    if (notificationId <= 0) {
      throw ArgumentError.value(notificationId, 'notificationId');
    }
    await markSelected([notificationId],
        replyIds: [if (replyId != null && replyId > 0) replyId],
        session: session);
  }

  Future<void> markSelected(List<int> ids,
      {required List<int> replyIds, PublishSessionScope? session}) async {
    _checkSession();
    final response = await _dio.post(
      '/notifications/read-selected',
      data: {'ids': ids},
      options: session == null ? null : Options(extra: session.requestExtra),
    );
    _ensureSuccessful(response, '标记通知已读失败');
    await _syncSystemRead(response, fallback: {
      'ids': ids,
      if (replyIds.isNotEmpty) 'reply_ids': replyIds,
    });
  }

  Future<void> markAllRead({
    bool repliesOnly = false,
    PublishSessionScope? session,
  }) async {
    _checkSession();
    final response = await _dio.post(
      repliesOnly ? '/notifications/replies/read' : '/notifications/read',
      options: session == null ? null : Options(extra: session.requestExtra),
    );
    _ensureSuccessful(response, '全部标记已读失败');
    await _syncSystemRead(response);
  }

  Future<void> markReplyRead(
      {required int postId,
      required int replyId,
      PublishSessionScope? session}) async {
    _checkSession();
    if (postId <= 0 || replyId <= 0) throw ArgumentError('帖子和回复 ID 必须为正数');
    Response<dynamic> response;
    try {
      response = await _dio.post('/notifications/read-selected',
          data: {
            'post_id': postId,
            'reply_id': replyId,
          },
          options:
              session == null ? null : Options(extra: session.requestExtra));
      if (response.statusCode == 400) {
        return _markLegacyReplyRead(postId, replyId, session);
      }
    } on DioException catch (error) {
      if (error.response?.statusCode != 400) rethrow;
      return _markLegacyReplyRead(postId, replyId, session);
    }
    _ensureSuccessful(response, '标记回复已读失败');
    await _syncSystemRead(response, fallback: {
      'reply_ids': [replyId]
    });
  }

  Future<void> _markLegacyReplyRead(
      int postId, int replyId, PublishSessionScope? session) async {
    // 旧服务只接受通知 ID。按账号内列表的帖子＋回复精确反查，不能退化为全部已读。
    String? cursor;
    final cursors = <String>{};
    for (var page = 0; page < 20; page++) {
      _checkSession();
      final response = await _dio.get('/notifications', queryParameters: {
        'limit': 50,
        if (cursor != null) 'cursor': cursor,
      });
      _checkSession();
      _ensureSuccessful(response, '读取回复通知失败');
      final data = response.data;
      final raw = data is List ? data : (data is Map ? data['items'] : null);
      if (raw is! List) throw StateError('通知接口返回格式错误');
      final ids = raw
          .whereType<Map>()
          .where((item) =>
              item['type'] == 'reply' &&
              _id(item['post_id']) == postId &&
              _id(item['related_id']) == replyId)
          .map((item) => _id(item['id']))
          .whereType<int>()
          .where((id) => id > 0)
          .toSet();
      if (ids.isNotEmpty) {
        for (final id in ids) {
          await markRead(id, replyId: replyId, session: session);
        }
        return;
      }
      final next = data is Map ? data['next_cursor']?.toString() : null;
      if (next == null || next.isEmpty || !cursors.add(next)) break;
      cursor = next;
    }
    throw StateError('未找到目标回复通知，保留未读状态');
  }

  static int? _id(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  Future<void> _syncSystemRead(Response<dynamic> response,
      {Map<String, dynamic>? fallback}) async {
    _checkSession();
    final data = response.data;
    final remote = data is Map ? data['read_receipt'] : null;
    final receipt = remote is Map
        ? Map<String, dynamic>.from(remote)
        : recipientUserId != null && recipientUserId! > 0 && fallback != null
            ? {'recipient_user_id': recipientUserId, ...fallback}
            : null;
    if (receipt == null ||
        (recipientUserId != null &&
            _id(receipt['recipient_user_id']) != recipientUserId)) {
      return;
    }
    await _applySystemRead(receipt);
  }

  // 系统通知栏清理失败时，下一次读取该账号未读状态只重送本机回执。
  Future<void> _retrySystemReads() async {
    final pending = _pendingSystemReads[recipientUserId];
    if (pending == null) return;
    for (final receipt in List.of(pending)) {
      _checkSession();
      if (pending.remove(receipt)) await _applySystemRead(receipt);
    }
    if (pending.isEmpty &&
        identical(_pendingSystemReads[recipientUserId], pending)) {
      _pendingSystemReads.remove(recipientUserId);
    }
  }

  Future<void> _applySystemRead(Map<String, dynamic> receipt) async {
    try {
      await const MethodChannel('shenliyuan/notification_open')
          .invokeMethod<void>('syncNotificationRead', receipt);
    } on MissingPluginException {
      // 非 Android 平台仍正常消费服务端已读状态。
    } on PlatformException {
      final account = _id(receipt['recipient_user_id']);
      if (account != null) (_pendingSystemReads[account] ??= []).add(receipt);
    }
  }

  void _ensureSuccessful(Response<dynamic> response, String message) {
    final statusCode = response.statusCode ?? 0;
    if (statusCode < 200 || statusCode >= 300) {
      throw StateError('$message（HTTP $statusCode）');
    }
  }
}
