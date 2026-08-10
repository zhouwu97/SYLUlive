import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/chat_detail_screen.dart';
import 'package:shenliyuan/screens/chat_list_screen.dart';
import 'package:shenliyuan/utils/app_navigator.dart' show appRouteObserver;

class _FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  _FakeAuthProvider(this.currentUser);

  final User currentUser;

  @override
  User get user => currentUser;

  @override
  bool get isLoggedIn => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

User _user(int id, String nickname) {
  return User(
    id: id,
    studentId: 'S$id',
    nickname: nickname,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

/// 构建带可开关 SSE 流的 mock Dio。
///
/// - `/messages/events`：每次请求新建一个打开的流（测试通过关闭流模拟断开）。
/// - `/messages/conversations`：会话列表。
/// - `/messages/conversations/:id`：单会话消息。
class _SseMockDio {
  _SseMockDio();

  final List<StreamController<Uint8List>> eventControllers = [];
  int conversationsRequestCount = 0;
  int conversationMessagesRequestCount = 0;
  List<Map<String, dynamic>> conversations = [];

  /// 为 true 时 `/messages/events` 请求直接失败（模拟持续断网）。
  bool failReconnect = false;

  Dio build() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/messages/events') {
            if (failReconnect) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                  message: 'offline',
                ),
              );
              return;
            }
            final controller = StreamController<Uint8List>();
            eventControllers.add(controller);
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: ResponseBody(controller.stream, 200),
              ),
            );
            return;
          }
          if (options.method == 'GET' &&
              options.path == '/messages/conversations') {
            conversationsRequestCount++;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: conversations,
              ),
            );
            return;
          }
          if (options.method == 'GET' &&
              options.path.startsWith('/messages/conversations/')) {
            conversationMessagesRequestCount++;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <dynamic>[],
              ),
            );
            return;
          }
          if (options.method == 'GET' && options.path.endsWith('/send-state')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{'can_send': true},
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

  Future<void> closeEvent(int index) => eventControllers[index].close();
}

/// 让出足够多的事件循环轮次，跑完 dio 请求链与流消费的异步阶段。
Future<void> _drainEvents() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _settleFrames(WidgetTester tester, {int count = 8}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('MessageProvider realtime state', () {
    test('connecting → connected → reconnecting → connected → disconnected',
        () async {
      final sse = _SseMockDio();
      final provider = MessageProvider(sse.build());

      expect(provider.realtimeState, MessageRealtimeState.disconnected);

      provider.syncSessionUser(1);
      await _drainEvents();
      expect(provider.realtimeState, MessageRealtimeState.connected);
      expect(sse.eventControllers, hasLength(1));

      // 服务端断开：流结束 → reconnecting。
      await sse.closeEvent(0);
      await _drainEvents();
      expect(provider.realtimeState, MessageRealtimeState.reconnecting);

      // 1s 退避后重连成功。
      await Future<void>.delayed(const Duration(seconds: 1));
      await _drainEvents();
      expect(sse.eventControllers, hasLength(2));
      expect(provider.realtimeState, MessageRealtimeState.connected);

      // 会话停止 → disconnected。
      provider.syncSessionUser(null);
      expect(provider.realtimeState, MessageRealtimeState.disconnected);
      provider.dispose();
    });

    test('连接失败进入 reconnecting 并退避重试', () async {
      var failFirst = true;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/messages/events') {
              if (failFirst) {
                failFirst = false;
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.connectionError,
                    message: 'offline',
                  ),
                );
                return;
              }
              final controller = StreamController<Uint8List>();
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: ResponseBody(controller.stream, 200),
                ),
              );
              return;
            }
            handler.reject(
              DioException(requestOptions: options, message: 'unexpected'),
            );
          },
        ),
      );
      final provider = MessageProvider(dio);
      provider.syncSessionUser(1);

      await _drainEvents();
      expect(provider.realtimeState, MessageRealtimeState.reconnecting);

      await Future<void>.delayed(const Duration(seconds: 1));
      await _drainEvents();
      expect(provider.realtimeState, MessageRealtimeState.connected);
      provider.dispose();
    });
  });

  testWidgets('ChatList：SSE 健康时无固定轮询，断开后启用 fallback', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final sse = _SseMockDio();
    final provider = MessageProvider(sse.build());
    // 模拟应用登录后建立的实时会话。
    provider.syncSessionUser(8);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(
            value: _FakeAuthProvider(_user(8, '我')),
          ),
          ChangeNotifierProvider<MessageProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          navigatorObservers: [appRouteObserver],
          home: const ChatListScreen(),
        ),
      ),
    );
    await _settleFrames(tester);

    // SSE 已连接：无 fallback polling。
    expect(provider.realtimeState, MessageRealtimeState.connected);
    expect(provider.fallbackPollingActive, isFalse);
    final baseline = sse.conversationsRequestCount;
    await tester.pump(const Duration(seconds: 31));
    expect(sse.conversationsRequestCount, baseline,
        reason: 'SSE connected 时不应有 30s 固定轮询');

    // 断开 SSE → 页面进入 fallback polling；保持断网以观察 fallback 行为。
    await sse.closeEvent(0);
    sse.failReconnect = true;
    await _settleFrames(tester);
    expect(provider.realtimeState, MessageRealtimeState.reconnecting);
    expect(provider.fallbackPollingActive, isTrue);

    // 1s 重连失败，继续 reconnecting；31s 后 fallback 轮询触发一次列表请求。
    await tester.pump(const Duration(seconds: 1));
    await _settleFrames(tester);
    await tester.pump(const Duration(seconds: 31));
    await _settleFrames(tester);
    expect(sse.conversationsRequestCount, greaterThan(baseline));

    // 网络恢复 → SSE 重连成功 → fallback 停止。
    sse.failReconnect = false;
    // 断网期间退避已增长到 15s 上限，pump 足够时间等待重连。
    await tester.pump(const Duration(seconds: 20));
    await _settleFrames(tester);
    expect(provider.realtimeState, MessageRealtimeState.connected);
    expect(provider.fallbackPollingActive, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    provider.dispose();
  });

  testWidgets('ChatDetail：SSE 健康时无固定轮询，恢复后只 reconciliation 一次', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final sse = _SseMockDio();
    final provider = MessageProvider(sse.build());
    // 模拟应用登录后建立的实时会话。
    provider.syncSessionUser(8);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(
            value: _FakeAuthProvider(_user(8, '我')),
          ),
          ChangeNotifierProvider<MessageProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          navigatorObservers: [appRouteObserver],
          home: ChatDetailScreen(
            conversationId: 42,
            targetUser: _user(3, '对方'),
          ),
        ),
      ),
    );
    await _settleFrames(tester);

    expect(provider.realtimeState, MessageRealtimeState.connected);
    expect(provider.fallbackPollingActive, isFalse);
    final baseline = sse.conversationMessagesRequestCount;
    await tester.pump(const Duration(seconds: 26));
    expect(sse.conversationMessagesRequestCount, baseline,
        reason: 'SSE connected 时不应有 25s 固定轮询');

    // 断开 → fallback polling 启动；保持断网观察 fallback 行为。
    await sse.closeEvent(0);
    sse.failReconnect = true;
    await _settleFrames(tester);
    expect(provider.realtimeState, MessageRealtimeState.reconnecting);
    expect(provider.fallbackPollingActive, isTrue);

    // 1s 重连失败，继续 reconnecting；26s 后 fallback 轮询触发一次消息刷新。
    await tester.pump(const Duration(seconds: 1));
    await _settleFrames(tester);
    await tester.pump(const Duration(seconds: 26));
    await _settleFrames(tester);
    expect(sse.conversationMessagesRequestCount, greaterThan(baseline));

    // 网络恢复 → SSE 重连成功 → fallback 停止，并执行一次 REST
    // reconciliation（refreshMessages + loadConversations 各一次）。
    final preReconnect = sse.conversationMessagesRequestCount;
    final preReconnectList = sse.conversationsRequestCount;
    sse.failReconnect = false;
    // 断网期间退避已增长到 15s 上限，pump 足够时间等待重连。
    await tester.pump(const Duration(seconds: 20));
    await _settleFrames(tester);
    expect(provider.realtimeState, MessageRealtimeState.connected);
    expect(provider.fallbackPollingActive, isFalse);
    expect(sse.conversationMessagesRequestCount, preReconnect + 1,
        reason: '重连后应执行一次当前会话 reconciliation');
    expect(sse.conversationsRequestCount, preReconnectList + 1,
        reason: '重连后应同步一次会话摘要');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    provider.dispose();
  });
}
