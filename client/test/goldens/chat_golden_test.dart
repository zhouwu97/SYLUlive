@Tags(['golden'])
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/chat_detail_screen.dart';
import 'package:shenliyuan/screens/chat_list_screen.dart';

import '../helpers/chat_test_fakes.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

/// PR3：私信链路第一批 Linux canonical Goldens。
///
/// 只收录静态、无网络、无无限动画的状态：
/// - 头像全部走空 URL fallback，避免 CachedNetworkImage 网络抖动；
/// - 不含 pending/loading spinner 场景（无限动画不可 golden）。
void main() {
  setUpAll(() async {
    await loadTestFonts();
  });

  group('chat list', () {
    testWidgets('empty light 360x800', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final provider = MessageProvider(chatListDio());
      await tester.pumpWidget(
        GoldenTestApp(home: _chatHome(const ChatListScreen(), provider)),
      );
      await _settle(tester, provider);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('baselines/chat/chat_list_empty_light_360x800.png'),
      );
      await _dispose(tester, provider);
    });

    testWidgets('populated with unread 390x844', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final provider = MessageProvider(
        chatListDio(conversations: [
          fakeConversationJson(
            id: 42,
            otherId: 3,
            nickname: '小林',
            content: '明天下午图书馆见',
            unreadCount: 2,
          ),
          fakeConversationJson(
            id: 43,
            otherId: 4,
            nickname: '小周',
            content: '算法竞赛笔记发你邮箱了',
          ),
        ]),
      );
      await tester.pumpWidget(
        GoldenTestApp(home: _chatHome(const ChatListScreen(), provider)),
      );
      await _settle(tester, provider);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('baselines/chat/chat_list_populated_light_390x844.png'),
      );
      await _dispose(tester, provider);
    });

    testWidgets('populated dark 360x800', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
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
      await tester.pumpWidget(
        GoldenTestApp(
          themeMode: ThemeMode.dark,
          home: _chatHome(const ChatListScreen(), provider),
        ),
      );
      await _settle(tester, provider);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('baselines/chat/chat_list_populated_dark_360x800.png'),
      );
      await _dispose(tester, provider);
    });
  });

  group('chat detail', () {
    testWidgets('empty light 390x844', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final provider = MessageProvider(chatDetailDio());
      await tester.pumpWidget(
        GoldenTestApp(
          home: _chatHome(
            ChatDetailScreen(
              conversationId: 42,
              targetUser: fakeChatUser(3, '对方'),
            ),
            provider,
          ),
        ),
      );
      await _settle(tester, provider);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('baselines/chat/chat_detail_empty_light_390x844.png'),
      );
      await _dispose(tester, provider);
    });

    testWidgets('empty large text 360x800', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final provider = MessageProvider(chatDetailDio());
      await tester.pumpWidget(
        GoldenTestApp(
          textScaler: GoldenTextProfile.large.scaler,
          home: _chatHome(
            ChatDetailScreen(
              conversationId: 42,
              targetUser: fakeChatUser(3, '对方'),
            ),
            provider,
          ),
        ),
      );
      await _settle(tester, provider);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('baselines/chat/chat_detail_empty_large_360x800.png'),
      );
      await _dispose(tester, provider);
    });

    testWidgets('text bubbles light 390x844', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final provider = MessageProvider(
        chatDetailDio(messages: [
          fakeMessageJson(
            id: 1,
            conversationId: 42,
            senderId: 3,
            content: '今天下午图书馆见',
            createdAt: '2026-06-14T08:30:00Z',
          ),
          fakeMessageJson(
            id: 2,
            conversationId: 42,
            senderId: 8,
            content: '可以，我带上学生证',
            createdAt: '2026-06-14T08:31:00Z',
            readAt: '2026-06-14T08:32:00Z',
          ),
          fakeMessageJson(
            id: 3,
            conversationId: 42,
            senderId: 3,
            content: '篮球课老地方集合',
            createdAt: '2026-06-14T08:33:00Z',
          ),
        ]),
      );
      await tester.pumpWidget(
        GoldenTestApp(
          home: _chatHome(
            ChatDetailScreen(
              conversationId: 42,
              targetUser: fakeChatUser(3, '对方'),
            ),
            provider,
          ),
        ),
      );
      await _settle(tester, provider);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('baselines/chat/chat_detail_bubbles_light_390x844.png'),
      );
      await _dispose(tester, provider);
    });
  });
}

Widget _chatHome(Widget screen, MessageProvider provider) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(
        value: FakeAuthProvider(fakeChatUser(8, '我')),
      ),
      ChangeNotifierProvider<MessageProvider>.value(value: provider),
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
    ],
    child: screen,
  );
}

/// 固定步进推进帧，避免 pumpAndSettle 被周期轮询 Timer 拖住。
Future<void> _settle(WidgetTester tester, MessageProvider provider) async {
  for (var index = 0; index < 12; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _dispose(WidgetTester tester, MessageProvider provider) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  provider.dispose();
}