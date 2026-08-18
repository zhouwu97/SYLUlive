import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/shuitie_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _FeedAuthProvider extends ChangeNotifier implements AuthProvider {
  _FeedAuthProvider({required this.client, required this.loggedIn});

  final Dio client;
  final bool loggedIn;

  @override
  User? get user => null;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  int get sessionGeneration => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // visibility_detector 在测试里用帧末回调而非内部 Timer，避免残留 pending timer。
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  testWidgets('feed keeps loading state while the first request is pending',
      (tester) async {
    final gate = Completer<void>();
    final page = await _pumpFeed(tester, gate: gate);
    await _pumpFrames(tester, count: 4);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete();
    await _pumpFrames(tester);
    await _disposeFeed(tester, page);
  });

  testWidgets('feed exposes an actionable error state', (tester) async {
    final page = await _pumpFeed(tester, fail: true);
    await _pumpFrames(tester);

    expect(page.postProvider.errorFor(1, sort: 'all'), isNotNull);
    expect(find.text('帖子加载失败'), findsOneWidget);
    expect(find.text('刷新试试'), findsOneWidget);
    await _disposeFeed(tester, page);
  });

  testWidgets('feed keeps the empty state distinct from loading and error',
      (tester) async {
    final page = await _pumpFeed(tester);
    await _pumpFrames(tester);

    expect(find.text('暂无帖子'), findsOneWidget);
    expect(find.text('帖子加载失败'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _disposeFeed(tester, page);
  });

  testWidgets('following feed shows the unlogged-in guard', (tester) async {
    final page = await _pumpFeed(tester);
    await _pumpFrames(tester);

    await tester.tap(find.text('关注'));
    await tester.pump(const Duration(milliseconds: 160));

    expect(find.text('登录后查看关注动态'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    await _disposeFeed(tester, page);
  });

  testWidgets('登录用户的最新信息流显示首页互动回复模块', (tester) async {
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [
        {
          'id': 11,
          'post_id': 100,
          'related_id': 511,
          'content': '首页测试回复',
          'post_title': '首页测试帖子',
          'created_at': '2026-08-18T10:00:00Z',
          'from_user': {'id': 2, 'nickname': '回复者', 'avatar': ''},
        },
      ],
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('最新'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );
    expect(find.text('互动回复'), findsOneWidget);
    expect(find.text('1 条新回复'), findsOneWidget);
    expect(find.text('回复者'), findsNothing);
    expect(find.text('首页测试回复'), findsNothing);
    await _disposeFeed(tester, page);
  });

  testWidgets('综合信息流也显示首页互动回复模块', (tester) async {
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [
        {
          'id': 12,
          'post_id': 101,
          'related_id': 512,
          'content': '综合页测试回复',
          'post_title': '综合页测试帖子',
          'created_at': '2026-08-18T10:00:00Z',
          'from_user': {'id': 3, 'nickname': '综合回复者', 'avatar': ''},
        },
      ],
    );
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );
    expect(find.text('互动回复'), findsOneWidget);
    expect(find.text('1 条新回复'), findsOneWidget);
    expect(find.text('综合回复者'), findsNothing);
    expect(find.text('综合页测试回复'), findsNothing);
    await _disposeFeed(tester, page);
  });

  testWidgets('首次加载未读回复失败时不展示提醒但保留信息流错误态', (tester) async {
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadRequestFail: true,
      fail: true,
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('最新'));
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsNothing,
    );
    expect(find.text('帖子加载失败'), findsOneWidget);
    await _disposeFeed(tester, page);
  });

  testWidgets('已有未读提醒后刷新失败仍保留旧提醒', (tester) async {
    var failUnread = false;
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [
        {
          'id': 11,
          'post_id': 100,
          'related_id': 511,
          'content': '首页测试回复',
          'post_title': '首页测试帖子',
          'created_at': '2026-08-18T10:00:00Z',
          'from_user': {'id': 2, 'nickname': '回复者', 'avatar': ''},
        },
      ],
      unreadFailCondition: () => failUnread,
    );
    await _pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );
    expect(find.text('1 条新回复'), findsOneWidget);

    // 模拟网络抖动刷新失败
    failUnread = true;
    await tester.fling(
      find.byType(CustomScrollView).first,
      const Offset(0, 300),
      1000,
    );
    await _pumpFrames(tester);

    // 提醒仍保留在界面上
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );
    expect(find.text('1 条新回复'), findsOneWidget);
    await _disposeFeed(tester, page);
  });

  testWidgets('点击回复所属原帖404时自动调用markRead并清除死提醒', (tester) async {
    final markedReadIds = <int>[];
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [
        {
          'id': 11,
          'post_id': 999,
          'related_id': 511,
          'content': '死提醒测试回复',
          'post_title': '已被删除的帖子',
          'created_at': '2026-08-18T10:00:00Z',
          'from_user': {'id': 2, 'nickname': '回复者', 'avatar': ''},
        },
      ],
      post404Id: 999,
      onMarkRead: (ids) => markedReadIds.addAll(ids),
    );
    await _pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );

    // 点击单条提醒打开
    await tester.tap(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
    );
    await _pumpFrames(tester);

    expect(markedReadIds, contains(11));
    expect(find.text('原帖已删除，已移除提醒'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsNothing,
    );
    await _disposeFeed(tester, page);
  });
}

Future<_FeedTestPage> _pumpFeed(
  WidgetTester tester, {
  Completer<void>? gate,
  bool fail = false,
  bool loggedIn = false,
  bool unreadRequestFail = false,
  bool Function()? unreadFailCondition,
  int? post404Id,
  void Function(List<int> ids)? onMarkRead,
  List<Map<String, dynamic>> unreadItems = const [],
}) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (options.path == '/posts') {
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
              data: <String, dynamic>{
                'posts': <dynamic>[],
                'pinned_posts': <dynamic>[],
                'total': 0,
              },
            ),
          );
          return;
        }
        if (options.path == '/notifications/replies/unread') {
          final shouldFail =
              unreadRequestFail || (unreadFailCondition?.call() ?? false);
          if (shouldFail) {
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
              data: {
                'count': unreadItems.length,
                'items': unreadItems,
              },
            ),
          );
          return;
        }
        if (post404Id != null && options.path == '/posts/$post404Id') {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(
                requestOptions: options,
                statusCode: 404,
                data: {'error': 'not found'},
              ),
              type: DioExceptionType.badResponse,
            ),
          );
          return;
        }
        if (options.path == '/notifications/read-selected') {
          final body = options.data as Map<String, dynamic>?;
          final ids = (body?['ids'] as List<dynamic>?)?.cast<int>() ?? [];
          onMarkRead?.call(ids);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'success': true},
            ),
          );
          return;
        }
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: <dynamic>[],
          ),
        );
      },
    ),
  );

  final auth = _FeedAuthProvider(client: dio, loggedIn: loggedIn);
  final postProvider = PostProvider(dio, enableCache: false);
  final messageProvider = MessageProvider(Dio());
  final themeProvider = ThemeProvider(loadOnStart: false);
  final sectionProvider = WaterSectionProvider(null);
  final widget = MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<PostProvider>.value(value: postProvider),
      ChangeNotifierProvider<MessageProvider>.value(value: messageProvider),
      ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
      ChangeNotifierProvider<WaterSectionProvider>.value(
          value: sectionProvider),
    ],
    child: const MaterialApp(home: ShuitieScreen()),
  );
  await tester.pumpWidget(widget);
  await tester.pump();
  return _FeedTestPage(
    auth: auth,
    postProvider: postProvider,
    messageProvider: messageProvider,
    themeProvider: themeProvider,
    sectionProvider: sectionProvider,
  );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _disposeFeed(WidgetTester tester, _FeedTestPage page) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  page.auth.dispose();
  page.postProvider.dispose();
  page.messageProvider.dispose();
  page.themeProvider.dispose();
  page.sectionProvider.dispose();
}

class _FeedTestPage {
  const _FeedTestPage({
    required this.auth,
    required this.postProvider,
    required this.messageProvider,
    required this.themeProvider,
    required this.sectionProvider,
  });

  final _FeedAuthProvider auth;
  final PostProvider postProvider;
  final MessageProvider messageProvider;
  final ThemeProvider themeProvider;
  final WaterSectionProvider sectionProvider;
}
