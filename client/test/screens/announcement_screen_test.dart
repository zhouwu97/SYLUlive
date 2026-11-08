import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/announcement_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/widgets/glass_container.dart';
import '../helpers/golden_viewport.dart';

class _AnnouncementAdapter implements HttpClientAdapter {
  final List<String> requests = [];
  bool failRead = false;
  bool empty = false;
  bool failLoad = false;
  Completer<void>? pendingLoad;

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
    if (key == 'GET:/notices') await pendingLoad?.future;

    final (status, body) = switch (key) {
      'GET:/notices' => failLoad
          ? (500, '{"error":"test failure"}')
          : (200, empty ? '[]' : _allAnnouncements),
      'GET:/notices/unread' => (200, _unreadAnnouncements),
      'POST:/notices/1/read' => failRead
          ? (500, '{"error":"test failure"}')
          : (200, '{"message":"ok"}'),
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
    "is_pinned": true,
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
    "is_pinned": true,
    "content": "紧急公告正文",
    "created_by": 1,
    "created_at": "2026-07-13T10:00:00Z",
    "priority": "urgent",
    "status": "published"
  }
]''';

void main() {
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final state in ['empty', 'load-error', 'leave-loading']) {
    testWidgets('公告材质保留加载、空态、失败和异步退出：$state', (tester) async {
      final adapter = _AnnouncementAdapter()
        ..empty = true
        ..failLoad = state == 'load-error'
        ..pendingLoad = Completer<void>();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
        ..httpClientAdapter = adapter;
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => _TestAuthProvider(dio, loggedIn: false)),
          ChangeNotifierProvider(
            create: (_) => ThemeProvider(loadOnStart: false)),
        ],
        child: const MaterialApp(home: AnnouncementScreen()),
      ));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      if (state == 'leave-loading') {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      adapter.pendingLoad!.complete();
      await tester.pumpAndSettle();
      if (state != 'leave-loading') {
        expect(find.text('暂无公告'), findsOneWidget);
      }
      expect(adapter.requests, isNot(contains('GET:/notices/unread')));
      expect(tester.takeException(), isNull);
    });
  }

  for (final reduced in [false, true]) {
    testWidgets('公告连续展开收起保留背景、状态并可中断 reduced=$reduced', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setFrostedGlass(true);
      final adapter = _AnnouncementAdapter();
      final dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
        ..httpClientAdapter = adapter;
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider<AuthProvider>(
              create: (_) => _TestAuthProvider(dio, loggedIn: true)),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                  disableAnimations: reduced,
                  textScaler: const TextScaler.linear(1.3)),
              child: child!),
          home: const AnnouncementScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      final card = find.ancestor(
          of: find.text('未读紧急公告'), matching: find.byType(GlassContainer));
      final collapsed = tester.getSize(card).height;
      await tester.tap(find.text('未读紧急公告'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final intermediate = tester.getSize(card).height;
      expect(intermediate, greaterThan(collapsed));
      await tester.pumpAndSettle();
      final expanded = tester.getSize(card).height;
      expect(intermediate, lessThan(expanded));
      expect(find.text('紧急公告正文'), findsOneWidget);
      await tester.tap(find.text('未读紧急公告'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
          tester.getSize(card).height, inExclusiveRange(collapsed, expanded));
      await tester.tap(find.text('未读紧急公告'));
      await tester.pumpAndSettle();
      expect(tester.getSize(card).height, expanded);
      expect(adapter.requests.where((r) => r == 'GET:/notices'), hasLength(1));
      adapter.failRead = true;
      await tester.tap(find.text('标为已读'));
      await tester.pumpAndSettle();
      expect(find.text('标记公告已读失败，请稍后重试'), findsOneWidget);
      expect(find.text('未读公告'), findsOneWidget);
      adapter.failRead = false;
      await tester.tap(find.text('标为已读'));
      await tester.pumpAndSettle();
      expect(find.text('2 条，可随时查看'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

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

    await tester.tap(find.text('未读紧急公告'));
    await tester.pumpAndSettle();
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
