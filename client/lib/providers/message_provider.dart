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
  bool _conversationLoading = false;
  bool _messageLoading = false;
  bool _loadingMore = false;
  bool _sending = false;
  bool _hasMore = true;
  String? _conversationError;
  String? _messageError;
  int? _currentConversationId;
  int _messageRequestVersion = 0;
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
    clearMessages();
    _messageLoading = true;
    notifyListeners();
    await loadConversations(silent: true);

    if (_conversationError != null) {
      _messageError = _conversationError;
      _messageLoading = false;
      notifyListeners();
      return null;
    }

    Conversation? existingConversation;
    for (final conversation in _conversations) {
      final matchesForward = conversation.user1Id == currentUserId &&
          conversation.user2Id == targetUserId;
      final matchesReverse = conversation.user1Id == targetUserId &&
          conversation.user2Id == currentUserId;
      if (matchesForward || matchesReverse) {
        existingConversation = conversation;
        break;
      }
    }

    if (existingConversation == null) {
      prepareNewConversation();
      return null;
    }

    await loadMessages(existingConversation.id);
    return existingConversation.id;
  }

  Future<void> loadMessages(int conversationId) async {
    final requestVersion = ++_messageRequestVersion;
    _currentConversationId = conversationId;
    _messages = [];
    _hasMore = true;
    _messageError = null;
    _messageLoading = true;
    notifyListeners();

    try {
      final response = await _dio.get(
        '/messages/conversations/$conversationId',
        queryParameters: {'limit': _pageSize},
      );
      if (requestVersion != _messageRequestVersion) return;
      if (response.statusCode == 200 && response.data is List) {
        _messages = (response.data as List)
            .map((e) => Message.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _hasMore = _messages.length == _pageSize;
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

  Future<void> refreshMessages() async {
    final conversationId = _currentConversationId;
    if (conversationId == null || _messageLoading) return;
    if (_messages.isEmpty) {
      await loadMessages(conversationId);
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
      final byId = <int, Message>{
        for (final message in _messages) message.id: message,
        for (final message in latest) message.id: message,
      };
      _messages = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
      await markRead(conversationId);
      notifyListeners();
    } catch (e) {
      debugPrint('刷新消息失败: $e');
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

  Future<void> markRead(int conversationId) async {
    try {
      await _dio.post('/messages/conversations/$conversationId/read');
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
