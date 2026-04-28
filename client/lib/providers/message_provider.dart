import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../models/conversation.dart';

class MessageProvider extends ChangeNotifier {
  final Dio _dio;

  List<Conversation> _conversations = [];
  List<Message> _messages = [];
  bool _isLoading = false;

  List<Conversation> get conversations => _conversations;
  List<Message> get messages => _messages;
  bool get isLoading => _isLoading;

  MessageProvider(this._dio);

  Future<void> loadConversations() async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await _dio.get('/messages/conversations');
      if (response.statusCode == 200) {
        _conversations = (response.data as List)
            .map((e) => Conversation.fromJson(e))
            .toList();
      }
    } catch (e) {
      debugPrint('加载会话列表失败: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMessages(int conversationId) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await _dio.get('/messages/conversations/$conversationId');
      if (response.statusCode == 200) {
        _messages = (response.data as List)
            .map((e) => Message.fromJson(e))
            .toList();
      }
    } catch (e) {
      debugPrint('加载消息失败: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> sendMessage(int targetUserId, String content, {int? fileId}) async {
    try {
      final response = await _dio.post('/messages/$targetUserId', data: {
        'content': content,
        if (fileId != null) 'file_id': fileId,
      });

      if (response.statusCode == 201) {
        _messages.add(Message.fromJson(response.data));
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('发送消息失败: $e');
    }
    return false;
  }

  Future<void> startConversation(int userId) async {
    await loadConversations();
  }
}