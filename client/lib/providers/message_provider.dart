import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/conversation.dart';
import '../utils/app_feedback.dart';

class MessageProvider extends ChangeNotifier {
  static const int _pageSize = 30;
  static const int maxMessageLength = 2000;

  final Dio _dio;

  List<Conversation> _conversations = [];
  List<Message> _messages = [];
  final Map<int, List<Message>> _messageCache = {};
  final Map<int, bool> _hasMoreCache = {};
  bool _conversationLoading = false;
  bool _messageLoading = false;
  bool _loadingMore = false;
  bool _sending = false;
  bool _hasMore = true;
  String? _conversationError;
  String? _messageError;
  int? _currentConversationId;
  int _messageRequestVersion = 0;
  final Set<int> _refreshingConversationIds = {};
  final Map<int, int> _lastMarkedReadMessageIds = {};
  final Map<int, String> _drafts = {};

  List<Conversation> get conversations => _conversations;
  List<Message> get messages => _messages;
  bool get conversationLoading => _conversationLoading;
  bool get messageLoading => _messageLoading;
  bool get loadingMore => _loadingMore;
  bool get sending => _sending;
  bool get hasMore => _hasMore;
  String? get conversationError => _conversationError;
  String? get messageError => _messageError;
  int? get currentConversationId => _currentConversationId;

  MessageProvider(this._dio);

  String draftFor(int targetUserId) => _drafts[targetUserId] ?? '';

  void updateDraft(int targetUserId, String content) {
    if (content.isEmpty) {
      _drafts.remove(targetUserId);
    } else {
      _drafts[targetUserId] = content;
    }
  }

  void clearDraft(int targetUserId) {
    _drafts.remove(targetUserId);
  }

  Future<void> loadConversations({bool silent = false}) async {
    _conversationError = null;
    if (!silent) {
      _conversationLoading = true;
      notifyListeners();
    }

    try {
      final response = await _dio.get('/messages/conversations');
      if (response.statusCode == 200) {
        _conversations = (response.data as List)
            .map((e) =>
                Conversation.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } on DioException catch (e) {
      _conversationError = AppFeedback.dioErrorMessage(e, fallback: '加载会话列表失败');
    } catch (e) {
      _conversationError = '加载会话列表失败';
      debugPrint('加载会话列表失败: $e');
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
      return cachedConversation.id;
    }

    _messageRequestVersion++;
    _currentConversationId = null;
    _messages = [];
    _hasMore = true;
    _messageLoading = true;
    _loadingMore = false;
    notifyListeners();
    await loadConversations(silent: true);

    if (_conversationError != null) {
      _messageError = _conversationError;
      _messageLoading = false;
      notifyListeners();
      return null;
    }

    final existingConversation = _findConversation(currentUserId, targetUserId);

    if (existingConversation == null) {
      prepareNewConversation();
      return null;
    }

    await loadMessages(existingConversation.id, preferCache: true);
    return existingConversation.id;
  }

  Conversation? _findConversation(int currentUserId, int targetUserId) {
    for (final conversation in _conversations) {
      final matchesForward = conversation.user1Id == currentUserId &&
          conversation.user2Id == targetUserId;
      final matchesReverse = conversation.user1Id == targetUserId &&
          conversation.user2Id == currentUserId;
      if (matchesForward || matchesReverse) {
        return conversation;
      }
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
      await markRead(conversationId);
      if (requestVersion == _messageRequestVersion) {
        await refreshLatestMessages();
        if (aroundMessageId != null && !containsMessage(aroundMessageId)) {
          await loadAroundMessage(aroundMessageId);
        }
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
        _messages = (response.data as List)
            .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _hasMore = _messages.length == _pageSize;
        _rememberMessages(conversationId);
        await markRead(conversationId);
      }
    } on DioException catch (e) {
      if (requestVersion != _messageRequestVersion) return;
      _messageError = AppFeedback.dioErrorMessage(e, fallback: '加载消息失败');
    } catch (e) {
      if (requestVersion != _messageRequestVersion) return;
      _messageError = '加载消息失败';
      debugPrint('加载消息失败: $e');
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
    if (conversationId == null ||
        _loadingMore ||
        !_hasMore ||
        _messages.isEmpty) {
      return;
    }

    _loadingMore = true;
    notifyListeners();
    final oldestMessageId = _messages.first.id;
    try {
      final response = await _dio.get(
        '/messages/conversations/$conversationId',
        queryParameters: {
          'limit': _pageSize,
          'before_id': oldestMessageId,
        },
      );
      if (_currentConversationId != conversationId ||
          requestVersion != _messageRequestVersion) {
        return;
      }
      final older = (response.data as List)
          .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final knownIds = _messages.map((message) => message.id).toSet();
      _messages = [
        ...older.where((message) => !knownIds.contains(message.id)),
        ..._messages,
      ]..sort((a, b) => a.id.compareTo(b.id));
      _hasMore = older.length == _pageSize;
      _rememberMessages(conversationId);
    } on DioException catch (e) {
      if (requestVersion == _messageRequestVersion) {
        _messageError = AppFeedback.dioErrorMessage(e, fallback: '加载更早消息失败');
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

    if (_messages.isEmpty) {
      // Don't fall through to loadMessages – that would set _messageLoading
      // and trigger the full-screen spinner during a background poll.
      // Instead, do a silent fetch inline.
      try {
        final requestVersion = _messageRequestVersion;
        final response = await _dio.get(
          '/messages/conversations/$conversationId',
          queryParameters: {'limit': _pageSize},
        );
        if (_currentConversationId != conversationId ||
            requestVersion != _messageRequestVersion ||
            response.data is! List) {
          return;
        }
        _messages = (response.data as List)
            .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _hasMore = _messages.length == _pageSize;
        _rememberMessages(conversationId);
        _markReadIfNeeded(conversationId, currentUserId: currentUserId);
        notifyListeners();
      } catch (e) {
        debugPrint('静默刷新消息失败: $e');
      } finally {
        _refreshingConversationIds.remove(conversationId);
      }
      return;
    }

    final requestVersion = _messageRequestVersion;
    final afterId = _messages.last.id;
    try {
      final response = await _dio.get(
        '/messages/conversations/$conversationId',
        queryParameters: {
          'limit': _pageSize,
          'after_id': afterId,
        },
      );
      if (_currentConversationId != conversationId ||
          requestVersion != _messageRequestVersion ||
          response.data is! List) {
        return;
      }
      final latest = (response.data as List)
          .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (latest.isNotEmpty) {
        final byId = <int, Message>{
          for (final message in _messages) message.id: message,
          for (final message in latest) message.id: message,
        };
        _messages = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
        _rememberMessages(conversationId);
        _markReadIfNeeded(conversationId, currentUserId: currentUserId);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('刷新消息失败: $e');
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
      final latest = (response.data as List)
          .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final byId = <int, Message>{
        for (final message in _messages) message.id: message,
        for (final message in latest) message.id: message,
      };
      _messages = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
      _hasMore = _hasMore || latest.length == _pageSize;
      _rememberMessages(conversationId);
      _markReadIfNeeded(conversationId);
      notifyListeners();
    } catch (e) {
      debugPrint('刷新最新消息失败: $e');
    }
  }

  Future<void> loadAroundMessage(int messageId) async {
    final conversationId = _currentConversationId;
    if (conversationId == null || _messageLoading) return;

    final requestVersion = _messageRequestVersion;
    try {
      final response = await _dio.get(
        '/messages/conversations/$conversationId',
        queryParameters: {
          'limit': _pageSize,
          'around_id': messageId,
        },
      );
      if (_currentConversationId != conversationId ||
          requestVersion != _messageRequestVersion ||
          response.data is! List) {
        return;
      }
      final around = (response.data as List)
          .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final byId = <int, Message>{
        for (final message in _messages) message.id: message,
        for (final message in around) message.id: message,
      };
      _messages = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
      _hasMore = _hasMore || around.length == _pageSize;
      _rememberMessages(conversationId);
      _markReadIfNeeded(conversationId);
      notifyListeners();
    } catch (e) {
      debugPrint('加载目标消息失败: $e');
    }
  }

  Future<Message?> sendMessage(
    int targetUserId,
    String content, {
    int? fileId,
  }) async {
    final trimmed = content.trim();
    if (_sending || (trimmed.isEmpty && fileId == null)) return null;

    _sending = true;
    _messageError = null;
    notifyListeners();
    Timer? sendingGuard;
    sendingGuard = Timer(const Duration(seconds: 35), () {
      if (!_sending) return;
      _sending = false;
      _messageError = '发送超时，请检查网络后重试';
      notifyListeners();
    });
    try {
      final response = await _dio.post('/messages/$targetUserId', data: {
        'content': trimmed,
        if (fileId != null) 'file_id': fileId,
      });
      if (response.statusCode == 201) {
        final message =
            Message.fromJson(Map<String, dynamic>.from(response.data as Map));
        _currentConversationId = message.conversationId;
        if (!_messages.any((item) => item.id == message.id)) {
          _messages.add(message);
          _messages.sort((a, b) => a.id.compareTo(b.id));
          _rememberMessages(message.conversationId);
        }
        clearDraft(targetUserId);
        notifyListeners();
        await loadConversations(silent: true);
        return message;
      }
    } on DioException catch (e) {
      _messageError = AppFeedback.dioErrorMessage(e, fallback: '发送消息失败');
    } catch (e) {
      _messageError = '发送消息失败';
      debugPrint('发送消息失败: $e');
    } finally {
      sendingGuard.cancel();
      if (_sending) {
        _sending = false;
        notifyListeners();
      }
    }
    return null;
  }

  /// Only sends a /read request when the latest incoming message ID has changed
  /// for this conversation. Skips if the latest message is from the current user.
  void _markReadIfNeeded(int conversationId, {int? currentUserId}) {
    if (_messages.isEmpty) return;

    // Find the latest incoming message (not from current user).
    // If currentUserId is unknown, fall back to using the latest message ID.
    int? latestIncomingId;
    if (currentUserId != null) {
      for (var i = _messages.length - 1; i >= 0; i--) {
        if (_messages[i].senderId != currentUserId) {
          latestIncomingId = _messages[i].id;
          break;
        }
      }
      if (latestIncomingId == null) return; // All messages are from self
    } else {
      latestIncomingId = _messages.last.id;
    }

    final lastMarkedId = _lastMarkedReadMessageIds[conversationId];
    if (latestIncomingId == lastMarkedId) return;
    // Don't record yet – only record after the API call succeeds.
    markRead(conversationId, markedMessageId: latestIncomingId);
  }

  Future<void> markRead(
    int conversationId, {
    int? markedMessageId,
  }) async {
    try {
      await _dio.post('/messages/conversations/$conversationId/read');
      // Only record after success so that a failed request gets retried.
      if (markedMessageId != null) {
        _lastMarkedReadMessageIds[conversationId] = markedMessageId;
      } else if (_messages.isNotEmpty) {
        _lastMarkedReadMessageIds[conversationId] = _messages.last.id;
      }
      final index = _conversations
          .indexWhere((conversation) => conversation.id == conversationId);
      if (index >= 0 && _conversations[index].unreadCount != 0) {
        _conversations[index] = _conversations[index].copyWith(unreadCount: 0);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('标记消息已读失败: $e');
    }
  }

  void prepareNewConversation() {
    _messageRequestVersion++;
    _currentConversationId = null;
    _messages = [];
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
}
