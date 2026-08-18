import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../config/api_constants.dart';
import '../models/conversation.dart';
import '../models/message_send_state.dart';
import '../services/diagnostic_log_service.dart';
import '../services/emoji_favorite_service.dart';
import '../utils/app_feedback.dart';

/// 私信实时传输层状态。
///
/// 与页面 UI 状态（loading/error）分离：UI 是否显示错误提示由
/// “SSE 持续失败 AND fallback REST 也失败”共同决定，见各页面实现。
enum MessageRealtimeState {
  /// 未连接（未登录 / 会话已停止）。
  disconnected,

  /// 正在建立 SSE 连接。
  connecting,

  /// SSE 已建立，事件流正常消费中。
  connected,

  /// 连接断开，正在按退避策略重连。
  reconnecting,
}

class MessageProvider extends ChangeNotifier {
  static const int _pageSize = 30;
  static const Duration _sendTimeout = Duration(seconds: 35);
  static const Duration _maxRealtimeRetryDelay = Duration(seconds: 15);
  static const int maxMessageLength = 2000;

  final Dio _dio;
  final Random _random = Random.secure();

  List<Conversation> _conversations = [];
  List<Message> _messages = [];
  final Map<int, List<Message>> _messageCache = {};
  final Map<int, bool> _hasMoreCache = {};
  bool _conversationLoading = false;
  bool _messageLoading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _conversationError;
  String? _messageError;
  int? _currentConversationId;
  int? _activeConversationId;
  bool _activeConversationEmbedded = false;
  int? _messageFocusRequestId;
  int _messageRequestVersion = 0;
  int _nextLocalMessageId = -1;
  final Set<int> _refreshingConversationIds = {};
  final Map<int, int> _lastMarkedReadMessageIds = {};
  final Map<int, _MessageDraft> _drafts = {};
  final Map<String, _PendingMessageContext> _pendingMessages = {};
  bool _hasLoadedConversations = false;
  int? _sessionUserId;
  CancelToken? _eventCancelToken;
  int _realtimeGeneration = 0;
  bool _disposed = false;

  MessageRealtimeState _realtimeState = MessageRealtimeState.disconnected;
  bool _fallbackPollingActive = false;

  /// 当前 SSE 传输层状态。状态真正变化时才 notifyListeners。
  MessageRealtimeState get realtimeState => _realtimeState;

  /// 页面级 fallback polling 是否正在运行（SSE 不可用时由页面开启）。
  bool get fallbackPollingActive => _fallbackPollingActive;

  void _setRealtimeState(MessageRealtimeState next) {
    if (_realtimeState == next) return;
    _realtimeState = next;
    notifyListeners();
  }

  /// 页面启动/停止 fallback polling 时上报，供测试与诊断使用。
  void setFallbackPollingActive(bool active) {
    if (_fallbackPollingActive == active) return;
    _fallbackPollingActive = active;
    notifyListeners();
  }

  MessageProvider(this._dio);

  List<Conversation> get conversations => _conversations;
  List<Message> get messages => _messages;
  bool get conversationLoading => _conversationLoading;
  bool get messageLoading => _messageLoading;
  bool get loadingMore => _loadingMore;
  bool get sending => _messages.any((message) => message.isPending);
  bool get hasMore => _hasMore;
  String? get conversationError => _conversationError;
  String? get messageError => _messageError;
  int? get currentConversationId => _currentConversationId;
  int? get activeConversationId => _activeConversationId;
  bool get activeConversationEmbedded => _activeConversationEmbedded;
  bool get hasLoadedConversations => _hasLoadedConversations;
  int get unreadMessageCount => _conversations.fold<int>(
        0,
        (sum, conversation) => sum + conversation.unreadCount,
      );

  Message? get latestIncomingMessage {
    final userId = _sessionUserId;
    if (userId == null) return null;
    return latestIncomingMessageFor(userId);
  }

  Message? latestIncomingMessageFor(int userId) {
    for (var index = _messages.length - 1; index >= 0; index--) {
      final message = _messages[index];
      if (message.id > 0 && message.senderId != userId) return message;
    }
    return null;
  }

  String draftFor(int targetUserId) => _drafts[targetUserId]?.content ?? '';

  String? draftStickerFor(int targetUserId) => _drafts[targetUserId]?.stickerId;

  Message? latestCachedMessageForConversation(int conversationId) {
    final source = _currentConversationId == conversationId
        ? _messages
        : _messageCache[conversationId];
    if (source == null || source.isEmpty) return null;
    Message? latest;
    for (final message in source) {
      if (latest == null || message.createdAt.isAfter(latest.createdAt)) {
        latest = message;
      }
    }
    return latest;
  }

  void updateDraft(int targetUserId, String content) {
    final current = _drafts[targetUserId];
    final stickerId = current?.stickerId;
    if (content.isEmpty && stickerId == null) {
      _drafts.remove(targetUserId);
    } else {
      _drafts[targetUserId] = _MessageDraft(
        content: content,
        stickerId: stickerId,
      );
    }
  }

  void updateDraftSticker(int targetUserId, String? stickerId) {
    final normalized = stickerId?.trim();
    final selectedStickerId =
        normalized?.isNotEmpty == true ? normalized : null;
    final content = _drafts[targetUserId]?.content ?? '';
    if (content.isEmpty && selectedStickerId == null) {
      _drafts.remove(targetUserId);
    } else {
      _drafts[targetUserId] = _MessageDraft(
        content: content,
        stickerId: selectedStickerId,
      );
    }
  }

  void clearDraft(int targetUserId) {
    _drafts.remove(targetUserId);
  }

  void syncSessionUser(int? userId) {
    if (_sessionUserId == userId) return;
    _stopRealtime();
    _sessionUserId = userId;
    resetSession();
    if (userId != null) {
      unawaited(_runRealtimeLoop(userId, _realtimeGeneration));
    }
  }

  void resetSession() {
    _messageRequestVersion++;
    _conversations = [];
    _messages = [];
    _messageCache.clear();
    _hasMoreCache.clear();
    _refreshingConversationIds.clear();
    _lastMarkedReadMessageIds.clear();
    _drafts.clear();
    _pendingMessages.clear();

    _conversationLoading = false;
    _messageLoading = false;
    _loadingMore = false;
    _hasMore = true;
    _conversationError = null;
    _messageError = null;
    _currentConversationId = null;
    _activeConversationId = null;
    _activeConversationEmbedded = false;
    _messageFocusRequestId = null;
    _hasLoadedConversations = false;

    notifyListeners();
  }

  void setActiveConversation(
    int? conversationId, {
    bool embedded = false,
  }) {
    _activeConversationId = conversationId;
    _activeConversationEmbedded = conversationId != null && embedded;
  }

  Future<void> requestMessageFocus(int messageId) async {
    if (messageId <= 0) return;
    if (!containsMessage(messageId)) await loadAroundMessage(messageId);
    _messageFocusRequestId = messageId;
    notifyListeners();
  }

  int? takeMessageFocusRequest() {
    final messageId = _messageFocusRequestId;
    _messageFocusRequestId = null;
    return messageId;
  }

  Future<void> loadConversations({bool silent = false}) async {
    _conversationError = null;
    if (!silent) {
      _conversationLoading = true;
      notifyListeners();
    }

    try {
      final response = await _dio.get('/messages/conversations');
      if (response.statusCode == 200 && response.data is List) {
        _conversations = (response.data as List)
            .map(
              (item) => Conversation.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList();
        _hasLoadedConversations = true;
      }
    } on DioException catch (error) {
      _conversationError =
          AppFeedback.dioErrorMessage(error, fallback: '加载会话列表失败');
    } catch (error) {
      _conversationError = '加载会话列表失败';
      debugPrint('加载会话列表失败: $error');
    } finally {
      _conversationLoading = false;
      notifyListeners();
    }
  }

  Future<int?> openConversationWithUser({
    required int currentUserId,
    required int targetUserId,
  }) async {
    _messageError = null;
    final cachedConversation = _findConversation(currentUserId, targetUserId);
    if (cachedConversation != null) {
      await loadMessages(cachedConversation.id, preferCache: true);
      return _currentConversationId == cachedConversation.id
          ? cachedConversation.id
          : null;
    }

    // 先展示空聊天壳，轻量接口返回后再补入历史消息。
    prepareNewConversation(targetUserId: targetUserId);
    final requestVersion = _messageRequestVersion;
    try {
      final response = await _dio.get(
        '/messages/users/$targetUserId/conversation',
      );
      if (requestVersion != _messageRequestVersion) return null;
      final data = response.data;
      if (response.statusCode != 200 || data is! Map) return null;
      final rawConversation = data['conversation'];
      if (rawConversation is! Map) return null;
      final conversation = Conversation.fromJson(
        Map<String, dynamic>.from(rawConversation),
      );
      if (conversation.id <= 0) return null;
      await loadMessages(conversation.id, preferCache: true);
      return _currentConversationId == conversation.id ? conversation.id : null;
    } on DioException catch (error) {
      _messageError = AppFeedback.dioErrorMessage(error, fallback: '查询会话失败');
    } catch (error) {
      _messageError = '查询会话失败';
      debugPrint('查询私信会话失败: $error');
    }
    notifyListeners();
    return null;
  }

  Conversation? _findConversation(int currentUserId, int targetUserId) {
    for (final conversation in _conversations) {
      final matchesForward = conversation.user1Id == currentUserId &&
          conversation.user2Id == targetUserId;
      final matchesReverse = conversation.user1Id == targetUserId &&
          conversation.user2Id == currentUserId;
      if (matchesForward || matchesReverse) return conversation;
    }
    return null;
  }

  void _rememberMessages(int conversationId) {
    _messageCache[conversationId] = List<Message>.of(_messages);
    _hasMoreCache[conversationId] = _hasMore;
  }

  Future<void> loadMessages(
    int conversationId, {
    bool preferCache = false,
    int? aroundMessageId,
  }) async {
    final requestVersion = ++_messageRequestVersion;
    _currentConversationId = conversationId;
    _messageFocusRequestId = null;
    final cachedMessages = _messageCache[conversationId];
    final cacheContainsTarget = aroundMessageId == null ||
        cachedMessages?.any((message) => message.id == aroundMessageId) == true;
    if (preferCache && cachedMessages != null && cacheContainsTarget) {
      _messages = List<Message>.of(cachedMessages);
      _hasMore = _hasMoreCache[conversationId] ?? true;
      _messageError = null;
      _messageLoading = false;
      _loadingMore = false;
      notifyListeners();
      await refreshLatestMessages();
      if (requestVersion == _messageRequestVersion &&
          aroundMessageId != null &&
          !containsMessage(aroundMessageId)) {
        await loadAroundMessage(aroundMessageId);
      }
      return;
    }

    _messages = [];
    _hasMore = true;
    _messageError = null;
    _messageLoading = true;
    notifyListeners();

    try {
      final response = await _dio.get(
        '/messages/conversations/$conversationId',
        queryParameters: {
          'limit': _pageSize,
          if (aroundMessageId != null) 'around_id': aroundMessageId,
        },
      );
      if (requestVersion != _messageRequestVersion) return;
      if (response.statusCode == 200 && response.data is List) {
        _messages = _parseMessages(response.data as List);
        _sortMessages();
        _hasMore = _messages.length == _pageSize;
        _rememberMessages(conversationId);
      }
    } on DioException catch (error) {
      if (requestVersion != _messageRequestVersion) return;
      _messageError = AppFeedback.dioErrorMessage(error, fallback: '加载消息失败');
    } catch (error) {
      if (requestVersion != _messageRequestVersion) return;
      _messageError = '加载消息失败';
      debugPrint('加载消息失败: $error');
    } finally {
      if (requestVersion == _messageRequestVersion) {
        _messageLoading = false;
        notifyListeners();
      }
    }
  }

  bool containsMessage(int messageId) {
    return _messages.any((message) => message.id == messageId);
  }

  Future<void> loadOlderMessages() async {
    final conversationId = _currentConversationId;
    final requestVersion = _messageRequestVersion;
    final oldestMessageId = _messages
        .where((message) => message.id > 0)
        .map((message) => message.id)
        .fold<int?>(
            null, (oldest, id) => oldest == null || id < oldest ? id : oldest);
    if (conversationId == null ||
        _loadingMore ||
        !_hasMore ||
        oldestMessageId == null) {
      return;
    }

    _loadingMore = true;
    notifyListeners();
    try {
      final response = await _dio.get(
        '/messages/conversations/$conversationId',
        queryParameters: {'limit': _pageSize, 'before_id': oldestMessageId},
      );
      if (_currentConversationId != conversationId ||
          requestVersion != _messageRequestVersion ||
          response.data is! List) {
        return;
      }
      final older = _parseMessages(response.data as List);
      _mergeCurrentMessages(older);
      _hasMore = older.length == _pageSize;
      _rememberMessages(conversationId);
    } on DioException catch (error) {
      if (requestVersion == _messageRequestVersion) {
        _messageError =
            AppFeedback.dioErrorMessage(error, fallback: '加载更早消息失败');
      }
    } finally {
      if (requestVersion == _messageRequestVersion) {
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  Future<void> refreshMessages({int? currentUserId}) async {
    final conversationId = _currentConversationId;
    if (conversationId == null || _messageLoading) return;
    if (!_refreshingConversationIds.add(conversationId)) return;

    final requestVersion = _messageRequestVersion;
    final afterId = _latestServerMessageId;
    try {
      final response = await _dio.get(
        '/messages/conversations/$conversationId',
        queryParameters: {
          'limit': _pageSize,
          if (afterId != null) 'after_id': afterId,
        },
      );
      if (_currentConversationId != conversationId ||
          requestVersion != _messageRequestVersion ||
          response.data is! List) {
        return;
      }
      final latest = _parseMessages(response.data as List);
      if (latest.isNotEmpty) {
        _mergeCurrentMessages(latest);
        _hasMore = afterId == null ? latest.length == _pageSize : _hasMore;
        _rememberMessages(conversationId);
        notifyListeners();
      }
    } catch (error) {
      debugPrint('刷新消息失败: $error');
    } finally {
      _refreshingConversationIds.remove(conversationId);
    }
  }

  Future<void> refreshLatestMessages() async {
    final conversationId = _currentConversationId;
    if (conversationId == null || _messageLoading) return;

    final requestVersion = _messageRequestVersion;
    try {
      final response = await _dio.get(
        '/messages/conversations/$conversationId',
        queryParameters: {'limit': _pageSize},
      );
      if (_currentConversationId != conversationId ||
          requestVersion != _messageRequestVersion ||
          response.data is! List) {
        return;
      }
      final latest = _parseMessages(response.data as List);
      _mergeCurrentMessages(latest);
      _hasMore = _hasMore || latest.length == _pageSize;
      _rememberMessages(conversationId);
      notifyListeners();
    } catch (error) {
      debugPrint('刷新最新消息失败: $error');
    }
  }

  Future<void> loadAroundMessage(int messageId) async {
    final conversationId = _currentConversationId;
    if (conversationId == null || _messageLoading) return;

    final requestVersion = _messageRequestVersion;
    try {
      final response = await _dio.get(
        '/messages/conversations/$conversationId',
        queryParameters: {'limit': _pageSize, 'around_id': messageId},
      );
      if (_currentConversationId != conversationId ||
          requestVersion != _messageRequestVersion ||
          response.data is! List) {
        return;
      }
      final around = _parseMessages(response.data as List);
      _mergeCurrentMessages(around);
      _hasMore = _hasMore || around.length == _pageSize;
      _rememberMessages(conversationId);
      notifyListeners();
    } catch (error) {
      debugPrint('加载目标消息失败: $error');
    }
  }

  Future<Message?> sendMessage(
    int targetUserId,
    String content, {
    int? fileId,
    String? stickerId,
    int? senderId,
    String? localImagePath,
  }) {
    final trimmed = content.trim();
    final normalizedStickerId = stickerId?.trim();
    final hasSticker = normalizedStickerId?.isNotEmpty == true;
    if (trimmed.isEmpty && fileId == null && !hasSticker) {
      return Future.value(null);
    }
    if (fileId != null && hasSticker) return Future.value(null);
    final pending = _insertPendingMessage(
      targetUserId: targetUserId,
      content: trimmed,
      fileId: fileId,
      stickerId: hasSticker ? normalizedStickerId : null,
      senderId: senderId,
      localImagePath: localImagePath,
    );
    return _sendPendingMessage(targetUserId, pending.clientMessageId!);
  }

  Future<Message?> sendImageMessage(
    int targetUserId,
    XFile image, {
    int? senderId,
  }) async {
    final pending = _insertPendingMessage(
      targetUserId: targetUserId,
      content: '',
      senderId: senderId,
      localImagePath: image.path,
    );
    final clientMessageId = pending.clientMessageId!;
    try {
      final fileId = await _uploadImage(image);
      _updatePendingMessage(
        clientMessageId,
        (message) => message.copyWith(fileId: fileId),
      );
      return _sendPendingMessage(targetUserId, clientMessageId);
    } on DioException catch (error) {
      _markPendingFailed(
        clientMessageId,
        AppFeedback.dioErrorMessage(error, fallback: '图片上传失败'),
      );
    } catch (error) {
      _markPendingFailed(clientMessageId, '图片上传失败');
      debugPrint('私信图片上传失败: $error');
    }
    return null;
  }

  /// 发送已上传并归属当前账号的收藏图片，不重新下载或上传资源。
  Future<Message?> sendFavoriteImageMessage(
    int targetUserId,
    EmojiFavoriteItem favorite, {
    String content = '',
    int? senderId,
  }) {
    final fileId = favorite.fileId;
    if (favorite.type != EmojiFavoriteType.image ||
        fileId == null ||
        fileId <= 0) {
      return Future.value(null);
    }
    return sendMessage(
      targetUserId,
      content,
      fileId: fileId,
      senderId: senderId,
    );
  }

  /// 上传图片并返回文件 ID，供收藏流程复用现有上传接口。
  Future<int> uploadImage(XFile image) => _uploadImage(image);

  Future<Message?> sendStickerMessage(
    int targetUserId,
    String stickerId, {
    int? senderId,
  }) {
    return sendMessage(
      targetUserId,
      '',
      stickerId: stickerId,
      senderId: senderId,
    );
  }

  Future<Message?> retryMessage(
    int targetUserId,
    String clientMessageId,
  ) async {
    final failed = _messageByClientMessageID(clientMessageId);
    final pendingContext = _pendingMessages[clientMessageId];
    if (failed == null ||
        !failed.isFailed ||
        (pendingContext != null &&
            pendingContext.targetUserId != targetUserId)) {
      return null;
    }
    _updatePendingMessage(
      clientMessageId,
      (message) => message.copyWith(
        localStatus: MessageLocalStatus.pending,
        clearLocalError: true,
      ),
    );
    _messageError = null;
    notifyListeners();

    var pending = _messageByClientMessageID(clientMessageId)!;
    if (pending.fileId == null && pending.localImagePath != null) {
      try {
        final image = XFile(pending.localImagePath!);
        final fileId = await _uploadImage(image);
        _updatePendingMessage(
          clientMessageId,
          (message) => message.copyWith(fileId: fileId),
        );
        pending = _messageByClientMessageID(clientMessageId)!;
      } on DioException catch (error) {
        _markPendingFailed(
          clientMessageId,
          AppFeedback.dioErrorMessage(error, fallback: '图片上传失败'),
        );
        return null;
      } catch (error) {
        _markPendingFailed(clientMessageId, '图片上传失败');
        return null;
      }
    }
    return _sendPendingMessage(targetUserId, pending.clientMessageId!);
  }

  void deleteFailedMessage(String clientMessageId) {
    _messages.removeWhere(
      (message) =>
          message.clientMessageId == clientMessageId && message.isFailed,
    );
    for (final cached in _messageCache.values) {
      cached.removeWhere(
        (message) =>
            message.clientMessageId == clientMessageId && message.isFailed,
      );
    }
    _pendingMessages.remove(clientMessageId);
    _rememberCurrentMessages();
    notifyListeners();
  }

  Message _insertPendingMessage({
    required int targetUserId,
    required String content,
    int? fileId,
    String? stickerId,
    int? senderId,
    String? localImagePath,
  }) {
    final clientMessageId = _newClientMessageId();
    final pending = Message(
      id: _nextLocalMessageId--,
      conversationId: _currentConversationId ?? 0,
      senderId: senderId ?? _sessionUserId ?? 0,
      clientMessageId: clientMessageId,
      content: content,
      fileId: fileId,
      stickerId: stickerId,
      createdAt: DateTime.now().toUtc(),
      localStatus: MessageLocalStatus.pending,
      localImagePath: localImagePath,
    );
    _pendingMessages[clientMessageId] = _PendingMessageContext(
      targetUserId: targetUserId,
      originConversationId: _currentConversationId,
      message: pending,
    );
    _messageError = null;
    _messages.add(pending);
    _sortMessages();
    _rememberCurrentMessages();
    notifyListeners();
    return pending;
  }

  Future<Message?> _sendPendingMessage(
    int targetUserId,
    String clientMessageId,
  ) async {
    final pending = _messageByClientMessageID(clientMessageId);
    if (pending == null) return null;
    if (pending.content.isEmpty &&
        pending.fileId == null &&
        !pending.isSticker) {
      _markPendingFailed(clientMessageId, '消息内容不能为空');
      return null;
    }

    final cancelToken = CancelToken();
    final timeoutTimer = Timer(
      _sendTimeout,
      () => cancelToken.cancel('发送超时'),
    );
    try {
      final response = await _dio.post(
        '/messages/$targetUserId',
        data: {
          'content': pending.content,
          if (pending.fileId != null) 'file_id': pending.fileId,
          if (pending.isSticker) 'sticker_id': pending.stickerId,
          'client_message_id': clientMessageId,
        },
        cancelToken: cancelToken,
        options: Options(
          sendTimeout: _sendTimeout,
          receiveTimeout: _sendTimeout,
        ),
      );
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          response.data is Map) {
        final serverMessage = Message.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        _replacePendingWithServer(clientMessageId, serverMessage);
        // 发送成功后后台校验服务器图片资源可用性，避免发送方本地预览
        // 掩盖服务器坏图；仅记录诊断，不改动消息发送状态。
        if (serverMessage.fileId != null) {
          unawaited(_verifyRemoteMedia(serverMessage));
        }
        unawaited(loadConversations(silent: true));
        return serverMessage;
      }
      _markPendingFailed(clientMessageId, '发送消息失败');
    } on DioException catch (error) {
      final message = CancelToken.isCancel(error)
          ? '发送超时，请检查网络后重试'
          : AppFeedback.dioErrorMessage(error, fallback: '发送消息失败');
      _markPendingFailed(clientMessageId, message);
    } catch (error) {
      _markPendingFailed(clientMessageId, '发送消息失败');
      debugPrint('发送消息失败: $error');
    } finally {
      timeoutTimer.cancel();
    }
    return null;
  }

  /// 后台校验服务器图片资源是否真实可读（Authenticated GET）。
  ///
  /// 发送成功只是消息已确认；图片是否能在对方/重启后显示取决于服务器资源。
  /// 这里收到首个字节即视为可用并取消下载，既不整张下载也避免本地文件
  /// 长期掩盖服务器坏图；失败仅写入诊断日志 `pm_media_remote_verify_failed`。
  Future<void> _verifyRemoteMedia(Message message) async {
    final url = message.imageUrl;
    if (url.isEmpty) return;
    final cancelToken = CancelToken();
    try {
      await _dio.get<List<int>>(
        ApiConstants.fullUrl(url),
        options: Options(responseType: ResponseType.bytes),
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (received > 0) cancelToken.cancel();
        },
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) return; // 已收到首字节，视为可用
      DiagnosticLogService.instance.record(
        level: 'error',
        source: 'pm',
        type: 'pm_media_remote_verify_failed',
        eventCode: 'pm_media_remote_verify_failed',
        category: 'pm',
        summary: '私信图片服务器资源校验失败',
        detail: 'fileId=${message.fileId} url=$url',
        httpStatus: error.response?.statusCode,
        operation: 'verify_remote_media',
        result: 'failure',
        metadata: {
          'fileId': message.fileId ?? -1,
          'messageId': message.stableKey,
          'senderId': message.senderId,
        },
      );
    } catch (_) {
      DiagnosticLogService.instance.record(
        level: 'error',
        source: 'pm',
        type: 'pm_media_remote_verify_failed',
        eventCode: 'pm_media_remote_verify_failed',
        category: 'pm',
        summary: '私信图片服务器资源校验失败',
        detail: 'fileId=${message.fileId} url=$url',
        operation: 'verify_remote_media',
        result: 'failure',
        metadata: {
          'fileId': message.fileId ?? -1,
          'messageId': message.stableKey,
          'senderId': message.senderId,
        },
      );
    }
  }

  void _replacePendingWithServer(
    String clientMessageId,
    Message serverMessage,
  ) {
    final visibleIndex = _indexByClientMessageID(clientMessageId);
    final existing = _messageByClientMessageID(clientMessageId);
    final confirmed = serverMessage.copyWith(
      clientMessageId: clientMessageId,
      localStatus: MessageLocalStatus.sent,
      localImagePath: existing?.localImagePath,
      clearLocalError: true,
    );

    // 先从所有缓存移除本地占位，避免切换会话后把回包写进当前会话。
    for (final cached in _messageCache.values) {
      cached.removeWhere(
        (message) => message.clientMessageId == clientMessageId,
      );
    }
    if (visibleIndex >= 0) {
      _messages[visibleIndex] = confirmed;
      _currentConversationId = confirmed.conversationId;
      _adoptConversationID(confirmed.conversationId);
      _sortMessages();
      _rememberMessages(confirmed.conversationId);
      _messageError = null;
    } else {
      final destination = _messageCache.putIfAbsent(
        confirmed.conversationId,
        () => <Message>[],
      );
      if (!destination.any((message) => message.id == confirmed.id)) {
        destination.add(confirmed);
        destination.sort(_compareMessages);
      }
    }
    _pendingMessages.remove(clientMessageId);
    _updateConversationFromMessage(confirmed);
    notifyListeners();
  }

  void _markPendingFailed(String clientMessageId, String error) {
    final isVisible = _indexByClientMessageID(clientMessageId) >= 0;
    _updatePendingMessage(
      clientMessageId,
      (message) => message.copyWith(
        localStatus: MessageLocalStatus.failed,
        localError: error,
      ),
    );
    if (isVisible) _messageError = error;
    notifyListeners();
  }

  void _updatePendingMessage(
    String clientMessageId,
    Message Function(Message message) update,
  ) {
    final pendingContext = _pendingMessages[clientMessageId];
    final source = _messageByClientMessageID(clientMessageId);
    if (source == null) return;
    final updated = update(source);
    if (pendingContext != null) pendingContext.message = updated;

    final currentIndex = _indexByClientMessageID(clientMessageId);
    if (currentIndex >= 0) {
      _messages[currentIndex] = updated;
      _rememberCurrentMessages();
    }
    for (final cached in _messageCache.values) {
      final cachedIndex = cached.indexWhere(
        (message) => message.clientMessageId == clientMessageId,
      );
      if (cachedIndex >= 0) cached[cachedIndex] = updated;
    }
  }

  int _indexByClientMessageID(String clientMessageId) {
    return _messages.indexWhere(
      (message) => message.clientMessageId == clientMessageId,
    );
  }

  Message? _messageByClientMessageID(String clientMessageId) {
    final currentIndex = _indexByClientMessageID(clientMessageId);
    if (currentIndex >= 0) return _messages[currentIndex];
    final pending = _pendingMessages[clientMessageId]?.message;
    if (pending != null) return pending;
    for (final cached in _messageCache.values) {
      for (final message in cached) {
        if (message.clientMessageId == clientMessageId) return message;
      }
    }
    return null;
  }

  Future<int> _uploadImage(XFile image) async {
    final filename = _safeUploadFilename(image.name);
    // 移动/桌面端从文件流式上传，避免整张图片读入内存；Web 走 fromBytes。
    final MultipartFile part;
    if (!kIsWeb && image.path.isNotEmpty) {
      part = await MultipartFile.fromFile(image.path, filename: filename);
    } else {
      final bytes = await image.readAsBytes();
      part = MultipartFile.fromBytes(bytes, filename: filename);
    }
    final formData = FormData.fromMap({'file': part});
    final response = await _dio.post(
      '/upload',
      data: formData,
      options: Options(
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    final data = response.data;
    final fileId = data is Map ? data['file_id'] : null;
    if (fileId is num && fileId.toInt() > 0) return fileId.toInt();
    throw StateError('上传接口未返回有效文件ID');
  }

  String _safeUploadFilename(String rawName) {
    final name = rawName.trim();
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif')) {
      return name;
    }
    return 'message_${DateTime.now().millisecondsSinceEpoch}.jpg';
  }

  String _newClientMessageId() {
    final randomPart = _random.nextInt(0x7fffffff).toRadixString(36);
    return '${_sessionUserId ?? 0}-${DateTime.now().microsecondsSinceEpoch}-$randomPart';
  }

  Future<void> markRead(int conversationId, {int? markedMessageId}) async {
    final latestIncomingId = markedMessageId ??
        (_currentConversationId == conversationId
            ? latestIncomingMessage?.id
            : null);
    if (latestIncomingId != null &&
        _lastMarkedReadMessageIds[conversationId] == latestIncomingId) {
      return;
    }
    try {
      await _dio.post('/messages/conversations/$conversationId/read');
      if (latestIncomingId != null) {
        _lastMarkedReadMessageIds[conversationId] = latestIncomingId;
      }
      final index = _conversations.indexWhere(
        (conversation) => conversation.id == conversationId,
      );
      if (index >= 0 && _conversations[index].unreadCount != 0) {
        _conversations[index] = _conversations[index].copyWith(unreadCount: 0);
        notifyListeners();
      }
    } catch (error) {
      debugPrint('标记消息已读失败: $error');
    }
  }

  Future<MessageSendState?> getSendState(int targetUserId) async {
    try {
      final response = await _dio.get('/messages/$targetUserId/send-state');
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return MessageSendState.fromJson(data);
      }
      if (data is Map) {
        return MessageSendState.fromJson(Map<String, dynamic>.from(data));
      }
      return null;
    } on DioException catch (error) {
      debugPrint('拉取私信发送状态失败: $error');
      return null;
    } catch (error) {
      debugPrint('拉取私信发送状态失败: $error');
      return null;
    }
  }

  void prepareNewConversation({int? targetUserId}) {
    _messageRequestVersion++;
    _currentConversationId = null;
    _messages = targetUserId == null
        ? []
        : _pendingMessages.values
            .where(
              (pending) =>
                  pending.targetUserId == targetUserId &&
                  pending.originConversationId == null,
            )
            .map((pending) => pending.message)
            .toList();
    _sortMessages();
    _messageError = null;
    _messageLoading = false;
    _loadingMore = false;
    _hasMore = false;
    notifyListeners();
  }

  void clearMessages() {
    _messageRequestVersion++;
    _currentConversationId = null;
    _messages = [];
    _messageError = null;
    _messageLoading = false;
    _loadingMore = false;
    _hasMore = true;
    notifyListeners();
  }

  List<Message> _parseMessages(List<dynamic> data) {
    return data
        .map(
          (item) => _reconcileServerMessage(
            Message.fromJson(Map<String, dynamic>.from(item as Map)),
          ),
        )
        .toList();
  }

  Message _reconcileServerMessage(Message message) {
    final clientMessageId = message.clientMessageId;
    if (clientMessageId == null) return message;

    final localMessage = _messageByClientMessageID(clientMessageId);
    _pendingMessages.remove(clientMessageId);
    return message.copyWith(
      localImagePath: localMessage?.localImagePath,
      localStatus: MessageLocalStatus.sent,
      clearLocalError: true,
    );
  }

  int? get _latestServerMessageId {
    int? latest;
    for (final message in _messages) {
      if (message.id > 0 && (latest == null || message.id > latest)) {
        latest = message.id;
      }
    }
    return latest;
  }

  void _mergeCurrentMessages(Iterable<Message> incoming) {
    for (final next in incoming) {
      final index = _messages.indexWhere(
        (existing) =>
            existing.id == next.id ||
            (next.clientMessageId != null &&
                existing.clientMessageId == next.clientMessageId),
      );
      if (index >= 0) {
        final existing = _messages[index];
        _messages[index] = next.copyWith(
          localImagePath: existing.localImagePath,
          localStatus: MessageLocalStatus.sent,
          clearLocalError: true,
        );
      } else {
        _messages.add(next);
      }
    }
    _sortMessages();
  }

  void _sortMessages() {
    _messages.sort(_compareMessages);
  }

  int _compareMessages(Message left, Message right) {
    if (left.id > 0 && right.id > 0) return left.id.compareTo(right.id);
    final byTime = left.createdAt.compareTo(right.createdAt);
    if (byTime != 0) return byTime;
    return left.stableKey.compareTo(right.stableKey);
  }

  void _adoptConversationID(int conversationId) {
    for (var index = 0; index < _messages.length; index++) {
      final message = _messages[index];
      if (message.conversationId == 0) {
        _messages[index] = message.copyWith(conversationId: conversationId);
      }
    }
  }

  void _rememberCurrentMessages() {
    final conversationId = _currentConversationId;
    if (conversationId != null) _rememberMessages(conversationId);
  }

  void _updateConversationFromMessage(Message message) {
    final index = _conversations.indexWhere(
      (conversation) => conversation.id == message.conversationId,
    );
    if (index < 0) {
      if (_hasLoadedConversations) unawaited(loadConversations(silent: true));
      return;
    }
    final conversation = _conversations[index];
    final previousLastMessage = conversation.lastMessage;
    final previousLastID = previousLastMessage?.id;
    final isIncoming = message.senderId != _sessionUserId;
    final hasComparableServerIDs =
        previousLastID != null && previousLastID > 0 && message.id > 0;
    final alreadyAccountedFor =
        hasComparableServerIDs && previousLastID >= message.id;
    final advancesPreview = previousLastMessage == null ||
        (hasComparableServerIDs
            ? message.id > previousLastID
            : !message.createdAt.isBefore(previousLastMessage.createdAt));
    _conversations[index] = conversation.copyWith(
      lastMessage: advancesPreview ? message : previousLastMessage,
      lastMessageAt:
          advancesPreview ? message.createdAt : conversation.lastMessageAt,
      unreadCount: isIncoming && !alreadyAccountedFor
          ? conversation.unreadCount + 1
          : conversation.unreadCount,
    );
    _conversations.sort(
      (left, right) => right.lastMessageAt.compareTo(left.lastMessageAt),
    );
  }

  void _stopRealtime() {
    _realtimeGeneration++;
    _eventCancelToken?.cancel('会话已切换');
    _eventCancelToken = null;
    _setRealtimeState(MessageRealtimeState.disconnected);
  }

  Future<void> _runRealtimeLoop(int userId, int generation) async {
    var retryDelay = const Duration(seconds: 1);
    _setRealtimeState(MessageRealtimeState.connecting);
    while (!_disposed &&
        _sessionUserId == userId &&
        generation == _realtimeGeneration) {
      final cancelToken = CancelToken();
      _eventCancelToken = cancelToken;
      try {
        final response = await _dio.get<ResponseBody>(
          '/messages/events',
          cancelToken: cancelToken,
          options: Options(
            responseType: ResponseType.stream,
            receiveTimeout: Duration.zero,
            headers: const {'Accept': 'text/event-stream'},
          ),
        );
        final body = response.data;
        if (body == null) throw StateError('实时消息响应为空');
        retryDelay = const Duration(seconds: 1);
        // 连接建立成功：通知页面停止 fallback polling 并执行一次 reconciliation。
        _setRealtimeState(MessageRealtimeState.connected);
        await _consumeEventStream(body, userId, generation);
        if (!_disposed &&
            _sessionUserId == userId &&
            generation == _realtimeGeneration) {
          // 事件流正常结束（服务端断开）：进入重连。
          _setRealtimeState(MessageRealtimeState.reconnecting);
        }
      } on DioException catch (error) {
        if (CancelToken.isCancel(error) ||
            _sessionUserId != userId ||
            generation != _realtimeGeneration) {
          return;
        }
        _setRealtimeState(MessageRealtimeState.reconnecting);
        debugPrint('私信实时连接中断，等待重连: $error');
      } catch (error) {
        if (_sessionUserId != userId || generation != _realtimeGeneration) {
          return;
        }
        _setRealtimeState(MessageRealtimeState.reconnecting);
        debugPrint('私信实时事件解析失败，等待重连: $error');
      }

      await Future<void>.delayed(retryDelay);
      final nextSeconds = min(
        retryDelay.inSeconds * 2,
        _maxRealtimeRetryDelay.inSeconds,
      );
      retryDelay = Duration(seconds: nextSeconds);
    }
    if (!_disposed) {
      _setRealtimeState(MessageRealtimeState.disconnected);
    }
  }

  Future<void> _consumeEventStream(
    ResponseBody body,
    int userId,
    int generation,
  ) async {
    var eventType = 'message';
    final dataLines = <String>[];
    final lines = body.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (_sessionUserId != userId || generation != _realtimeGeneration) return;
      if (line.isEmpty) {
        if (dataLines.isNotEmpty && eventType != 'ping') {
          final decoded = jsonDecode(dataLines.join('\n'));
          if (decoded is Map) {
            _applyRealtimeEvent(
              eventType,
              Map<String, dynamic>.from(decoded),
            );
          }
        }
        eventType = 'message';
        dataLines.clear();
      } else if (line.startsWith('event:')) {
        eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
  }

  @visibleForTesting
  void applyRealtimeEventForTest(
    String eventType,
    Map<String, dynamic> data,
  ) {
    _applyRealtimeEvent(eventType, data);
  }

  void _applyRealtimeEvent(
    String eventType,
    Map<String, dynamic> data,
  ) {
    if (eventType == 'message.created') {
      final rawMessage = data['message'];
      if (rawMessage is! Map) return;
      final message = Message.fromJson(
        Map<String, dynamic>.from(rawMessage),
      );
      final clientMessageId = message.clientMessageId;
      final pendingMatch = clientMessageId != null &&
          _pendingMessages.containsKey(clientMessageId);
      if (pendingMatch) {
        _replacePendingWithServer(clientMessageId, message);
        return;
      }
      if (_currentConversationId == message.conversationId) {
        _mergeCurrentMessages([message]);
        _rememberMessages(message.conversationId);
      } else {
        final cached = _messageCache[message.conversationId];
        if (cached != null && !cached.any((item) => item.id == message.id)) {
          cached.add(message);
          cached.sort((left, right) => left.id.compareTo(right.id));
        }
      }
      _updateConversationFromMessage(message);
      notifyListeners();
      return;
    }

    if (eventType == 'message.read') {
      final conversationId = (data['conversation_id'] as num?)?.toInt();
      final readByUserId = (data['read_by_user_id'] as num?)?.toInt();
      final readThroughMessageId =
          (data['read_through_message_id'] as num?)?.toInt();
      final readAt = DateTime.tryParse(data['read_at']?.toString() ?? '');
      if (conversationId == null || readByUserId == null || readAt == null) {
        return;
      }
      bool isCoveredByReceipt(Message message) {
        if (message.id <= 0 || message.senderId == readByUserId) return false;
        if (readThroughMessageId != null) {
          return message.id <= readThroughMessageId;
        }
        // 兼容尚未返回 read_through_message_id 的旧服务端。
        return !message.createdAt.isAfter(readAt);
      }

      var changed = false;
      if (_currentConversationId == conversationId) {
        for (var index = 0; index < _messages.length; index++) {
          final message = _messages[index];
          if (message.readAt == null && isCoveredByReceipt(message)) {
            _messages[index] = message.copyWith(readAt: readAt);
            changed = true;
          }
        }
        if (changed) _rememberMessages(conversationId);
      }
      final cached = _messageCache[conversationId];
      if (cached != null) {
        for (var index = 0; index < cached.length; index++) {
          final message = cached[index];
          if (message.readAt == null && isCoveredByReceipt(message)) {
            cached[index] = message.copyWith(readAt: readAt);
            changed = true;
          }
        }
      }
      if (changed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopRealtime();
    super.dispose();
  }
}

class _PendingMessageContext {
  _PendingMessageContext({
    required this.targetUserId,
    required this.originConversationId,
    required this.message,
  });

  final int targetUserId;
  final int? originConversationId;
  Message message;
}

class _MessageDraft {
  const _MessageDraft({required this.content, this.stickerId});

  final String content;
  final String? stickerId;
}
