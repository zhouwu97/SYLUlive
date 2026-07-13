import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/announcement_screen.dart';

class _AnnouncementAdapter implements HttpClientAdapter {
  final List<String> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final key = '${options.method}:${options.path}';
    requests.add(key);

    final (status, body) = switch (key) {
      'GET:/notices' => (200, _allAnnouncements),
      'GET:/notices/unread' => (200, _unreadAnnouncements),
      'POST:/notices/1/read' => (200, '{"message":"ok"}'),
      _ => (404, '{"error":"not mocked: $key"}'),
    };
    return ResponseBody(
      Stream.value(utf8.encode(body)),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

class _TestAuthProvider extends AuthProvider {
  _TestAuthProvider(super.dio, {required this.loggedIn})
      : super(loadStoredAuth: false);

  final bool loggedIn;

  @override
  bool get isLoggedIn => loggedIn;
}

const _allAnnouncements = '''[
  {
    "id": 2,
    "title": "已读历史公告",
    "content": "历史公告正文",
    "created_by": 1,
    "created_at": "2026-07-12T10:00:00Z",
    "priority": "normal",
    "status": "published"
  },
  {
    "id": 1,
    "title": "未读紧急公告",
    "content": "紧急公告正文",
    "created_by": 1,
    "created_at": "2026-07-13T10:00:00Z",
    "priority": "urgent",
    "status": "published"
  }
]''';

const _unreadAnnouncements = '''[
  {
    "id": 1,
    "title": "未读紧急公告",
    "content": "紧急公告正文",
    "created_by": 1,
    "created_at": "2026-07-13T10:00:00Z",
    "priority": "urgent",
    "status": "published"
  }
]''';

void main() {
  testWidgets('公告中心展示全部公告，标记已读后条目仍保留', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
    final adapter = _AnnouncementAdapter();
    dio.httpClientAdapter = adapter;
    final readIds = <int>[];

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _TestAuthProvider(dio, loggedIn: true),
          ),
          ChangeNotifierProvider(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
        ],
        child: MaterialApp(
          home: AnnouncementScreen(onAnnouncementRead: readIds.add),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('公告中心'), findsOneWidget);
    expect(find.text('未读公告'), findsOneWidget);
    expect(find.text('历史公告'), findsOneWidget);
    expect(find.text('未读紧急公告'), findsOneWidget);
    expect(find.text('已读历史公告'), findsOneWidget);

    await tester.tap(find.text('标为已读'));
    await tester.pumpAndSettle();

    expect(readIds, [1]);
    expect(find.text('未读紧急公告'), findsOneWidget);
    expect(find.text('已读历史公告'), findsOneWidget);
    expect(find.text('2 条，可随时查看'), findsOneWidget);
    expect(adapter.requests, contains('POST:/notices/1/read'));
  });

  testWidgets('未登录时只请求公开公告并展示最新内容', (tester) async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
    final adapter = _AnnouncementAdapter();
    dio.httpClientAdapter = adapter;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _TestAuthProvider(dio, loggedIn: false),
          ),
          ChangeNotifierProvider(
            create: (_) => ThemeProvider(loadOnStart: false),
          ),
        ],
        child: const MaterialApp(home: AnnouncementScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未读紧急公告'), findsOneWidget);
    expect(find.text('已读历史公告'), findsOneWidget);
    expect(adapter.requests, contains('GET:/notices'));
    expect(adapter.requests, isNot(contains('GET:/notices/unread')));
  });
}
