import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/chat_detail_screen.dart';
import 'package:shenliyuan/screens/chat_list_screen.dart';

import 'helpers/chat_test_fakes.dart';

/// PR3：私信链路统一三态占位（加载 / 空态 / 错误态）的交互契约测试。
void main() {
  group('ChatListScreen state placeholders', () {
    testWidgets('loading shows placeholder while conversations are in flight',
        (tester) async {
      final gate = Completer<void>();
      final provider = MessageProvider(chatListDio(gate: gate));
      await _pumpList(tester, provider);

      expect(find.text('加载会话中…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-list-loading')),
        findsOneWidget,
      );

      gate.complete();
      await _pumpFrames(tester);
      expect(find.text('加载会话中…'), findsNothing);
      await _disposePage(tester, provider);
    });

    testWidgets('error shows title, reason and a retry button',
        (tester) async {
      final provider = MessageProvider(chatListDio(fail: true));
      await _pumpList(tester, provider);

      expect(find.text('会话加载失败'), findsOneWidget);
      expect(find.textContaining('无法连接'), findsOneWidget);
      expect(find.text('重新加载'), findsOneWidget);
      await _disposePage(tester, provider);
    });

    testWidgets('empty shows invitation copy pointing at user profiles',
        (tester) async {
      final provider = MessageProvider(chatListDio());
      await _pumpList(tester, provider);

      expect(find.text('暂无私信'), findsOneWidget);
      expect(find.text('可以从其他用户主页发起聊天'), findsOneWidget);
      await _disposePage(tester, provider);
    });

    testWidgets('search without matches shows search empty copy',
        (tester) async {
      final provider = MessageProvider(
        chatListDio(conversations: [
          fakeConversationJson(
            id: 42,
            otherId: 3,
            nickname: '小林',
            content: '明天下午见',
          ),
        ]),
      );
      await _pumpList(tester, provider);

      await tester.enterText(
        find.byKey(const ValueKey('chat-conversation-search')),
        '找不到',
      );
      await tester.pump();

      expect(find.text('没有匹配的会话'), findsOneWidget);
      expect(find.text('换个关键词试试'), findsOneWidget);
      await _disposePage(tester, provider);
    });
  });

  group('ChatDetailScreen state placeholders', () {
    testWidgets('loading shows while history is still in flight',
        (tester) async {
      final gate = Completer<void>();
      final provider = MessageProvider(chatDetailDio(gate: gate));
      await _pumpDetail(tester, provider);

      expect(find.text('加载消息中…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-detail-loading')),
        findsOneWidget,
      );

      gate.complete();
      await _pumpFrames(tester);
      expect(find.text('加载消息中…'), findsNothing);
      await _disposePage(tester, provider);
    });

    testWidgets('error shows title, reason and retry action', (tester) async {
      final provider = MessageProvider(chatDetailDio(fail: true));
      await _pumpDetail(tester, provider);

      expect(find.text('消息加载失败'), findsOneWidget);
      expect(find.textContaining('无法连接'), findsOneWidget);
      expect(find.text('重新加载'), findsOneWidget);
      await _disposePage(tester, provider);
    });

    testWidgets('empty conversation invites a first message', (tester) async {
      final provider = MessageProvider(chatDetailDio());
      await _pumpDetail(tester, provider);

      expect(find.text('向 对方 打个招呼吧'), findsOneWidget);
      expect(find.text('发送第一条消息开始聊天'), findsOneWidget);
      await _disposePage(tester, provider);
    });
  });
}

Widget _app(Widget home, MessageProvider provider) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(
        value: FakeAuthProvider(fakeChatUser(8, '我')),
      ),
      ChangeNotifierProvider<MessageProvider>.value(value: provider),
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
    ],
    child: MaterialApp(home: home),
  );
}

Future<void> _pumpList(WidgetTester tester, MessageProvider provider) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(const ChatListScreen(), provider));
  await _pumpFrames(tester);
}

Future<void> _pumpDetail(WidgetTester tester, MessageProvider provider) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _app(
      ChatDetailScreen(conversationId: 42, targetUser: fakeChatUser(3, '对方')),
      provider,
    ),
  );
  await _pumpFrames(tester);
}

Future<void> _disposePage(WidgetTester tester, MessageProvider provider) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  provider.dispose();
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 10}) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}