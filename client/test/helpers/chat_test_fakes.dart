import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';

/// 私信（ChatList / ChatDetail）测试通用 fakes。
///
/// 与生产 [AuthProvider] 解耦：测试不需要真实登录态、偏好存储或平台通道。
class FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  FakeAuthProvider(this.currentUser);

  final User currentUser;

  @override
  User get user => currentUser;

  @override
  bool get isLoggedIn => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

User fakeChatUser(int id, String nickname) {
  return User(
    id: id,
    studentId: 'S$id',
    nickname: nickname,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

Map<String, dynamic> fakeUserJson(int id, String nickname) {
  return {
    'id': id,
    'student_id': 'S$id',
    'nickname': nickname,
    'created_at': '2026-01-01T00:00:00Z',
    'legal_consents_active': true,
  };
}

/// 构建会话 JSON；user1 固定为「我」(id=8)。
Map<String, dynamic> fakeConversationJson({
  required int id,
  required int otherId,
  required String nickname,
  required String content,
  int unreadCount = 0,
}) {
  return {
    'id': id,
    'user1_id': 8,
    'user2_id': otherId,
    'last_message_at': '2026-06-14T08:31:00Z',
    'user1': fakeUserJson(8, '我'),
    'user2': fakeUserJson(otherId, nickname),
    'unread_count': unreadCount,
    'last_message': fakeMessageJson(
      id: id * 10,
      conversationId: id,
      senderId: otherId,
      content: content,
    ),
  };
}

Map<String, dynamic> fakeMessageJson({
  required int id,
  required int conversationId,
  required int senderId,
  required String content,
  String createdAt = '2026-06-14T08:31:00Z',
  String? readAt,
  String? stickerId,
  String? filePath,
}) {
  return {
    'id': id,
    'conversation_id': conversationId,
    'sender_id': senderId,
    'content': content,
    'created_at': createdAt,
    if (readAt != null) 'read_at': readAt,
    if (stickerId != null) 'sticker_id': stickerId,
    if (filePath != null)
      'file': {
        'id': id,
        'hash': 'file_$id',
        'path': filePath,
        'size': 100,
        'mime_type': 'image/png',
      },
  };
}

/// 会话列表 Dio：默认返回空列表；可 [fail]、hold 或注入会话。
Dio chatListDio({
  Completer<void>? gate,
  bool fail = false,
  List<Map<String, dynamic>> conversations = const [],
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (options.method == 'GET' &&
            options.path == '/messages/conversations') {
          if (gate != null) await gate.future;
          if (fail) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'offline',
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: conversations,
            ),
          );
          return;
        }
        handler.reject(
          DioException(
            requestOptions: options,
            message: 'Unexpected request: ${options.method} ${options.path}',
          ),
        );
      },
    ),
  );
  return dio;
}

/// 聊天详情 Dio：消息加载 + 陌生人发送状态。
Dio chatDetailDio({
  Completer<void>? gate,
  bool fail = false,
  List<Map<String, dynamic>> messages = const [],
  Map<String, dynamic> sendState = const {'can_send': true},
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final path = options.path;
        if (options.method == 'GET' && path.startsWith('/messages/conversations/')) {
          if (gate != null) await gate.future;
          if (fail) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'offline',
              ),
            );
            return;
          }
          if (path == '/messages/conversations/42') {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: messages),
            );
            return;
          }
        }
        if (options.method == 'GET' && path.endsWith('/send-state')) {
          handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: sendState),
          );
          return;
        }
        if (options.method == 'POST' && path.endsWith('/read')) {
          handler.resolve(
            Response(requestOptions: options, statusCode: 200),
          );
          return;
        }
        handler.reject(
          DioException(
            requestOptions: options,
            message: 'Unexpected request: ${options.method} $path',
          ),
        );
      },
    ),
  );
  return dio;
}