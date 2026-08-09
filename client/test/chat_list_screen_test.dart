import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/chat_list_screen.dart';

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

void main() {
  testWidgets('conversation search filters local nickname and latest message',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = MessageProvider(
      _conversationDio([
        _conversation(
          id: 42,
          otherId: 3,
          nickname: '小林',
          content: '明天下午见',
        ),
        _conversation(
          id: 43,
          otherId: 4,
          nickname: '小周',
          content: '算法竞赛资料',
        ),
      ]),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(
            value: _FakeAuthProvider(_user(8, '我')),
          ),
          ChangeNotifierProvider<MessageProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: const MaterialApp(home: ChatListScreen()),
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('小林'), findsOneWidget);
    expect(find.text('小周'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('chat-conversation-search')),
      '算法',
    );
    await tester.pump();

    expect(find.text('小周'), findsOneWidget);
    expect(find.text('小林'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });

  testWidgets('conversation list uses the private-message visual hierarchy',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final provider = MessageProvider(
      _conversationDio([
        _conversation(
          id: 42,
          otherId: 3,
          nickname: '小林',
          content: '明天下午见',
          unreadCount: 2,
        ),
        _conversation(
          id: 43,
          otherId: 4,
          nickname: '小周',
          content: '算法竞赛资料',
        ),
      ]),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(
            value: _FakeAuthProvider(_user(8, '我')),
          ),
          ChangeNotifierProvider<MessageProvider>.value(value: provider),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: const MaterialApp(home: ChatListScreen()),
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('最近消息'), findsOneWidget);
    expect(
      tester
          .widget<AppBar>(find.byType(AppBar))
          .systemOverlayStyle
          ?.statusBarIconBrightness,
      Brightness.dark,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-conversation-search'))),
      const Size(368, 48),
    );
    final unreadTile = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('chat-conversation-42')),
    );
    final unreadDecoration = unreadTile.decoration as BoxDecoration;
    expect(unreadDecoration.color, isNot(Colors.transparent));
    expect(unreadDecoration.border, isNull);
    expect(unreadDecoration.boxShadow, isNull);
    expect(unreadDecoration.borderRadius, BorderRadius.zero);
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-conversation-42'))),
      const Size(368, 78),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
  });
}

Dio _conversationDio(List<Map<String, dynamic>> conversations) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.method == 'GET' &&
            options.path == '/messages/conversations') {
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

Map<String, dynamic> _conversation({
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
    'user1': _userJson(8, '我'),
    'user2': _userJson(otherId, nickname),
    'unread_count': unreadCount,
    'last_message': {
      'id': id * 10,
      'conversation_id': id,
      'sender_id': otherId,
      'content': content,
      'created_at': '2026-06-14T08:31:00Z',
    },
  };
}

Map<String, dynamic> _userJson(int id, String nickname) {
  return {
    'id': id,
    'student_id': 'S$id',
    'nickname': nickname,
    'created_at': '2026-01-01T00:00:00Z',
    'legal_consents_active': true,
  };
}

User _user(int id, String nickname) {
  return User(
    id: id,
    studentId: 'S$id',
    nickname: nickname,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
