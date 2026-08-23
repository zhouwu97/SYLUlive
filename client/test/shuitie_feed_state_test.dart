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
import 'package:shenliyuan/screens/notifications_screen.dart';
import 'package:shenliyuan/screens/shuitie_screen.dart';
import 'package:shenliyuan/services/reply_notification_state.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _FeedAuthProvider extends ChangeNotifier implements AuthProvider {
  _FeedAuthProvider({required this.client, required this.loggedIn}) {
    _currentUser = User(
      id: 1,
      studentId: 'test-student',
      nickname: '测试账号',
      createdAt: DateTime(2026, 1, 1),
    );
  }

  final Dio client;
  final bool loggedIn;
  late User _currentUser;
  int _sessionGeneration = 0;

  @override
  User? get user => loggedIn ? _currentUser : null;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  int get sessionGeneration => _sessionGeneration;

  @override
  Dio get dio => client;

  void advanceSession() {
    _sessionGeneration++;
    notifyListeners();
  }

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

  testWidgets('通知中心成功读取单条回复后首页提醒立即消失', (tester) async {
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [_unreadReply(11)],
      notificationItems: [_notification(11)],
    );
    await _pumpFrames(tester);

    unawaited(
      Navigator.of(tester.element(find.byType(ShuitieScreen))).push(
        MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('通知中心测试回复'));
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsNothing,
    );
    expect(find.text('1 条新回复'), findsNothing);
    await _disposeFeed(tester, page);
  });

  testWidgets('读取两条回复中的一条：首页只减少一条提醒', (tester) async {
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [_unreadReply(11), _unreadReply(12)],
    );
    await _pumpFrames(tester);

    ReplyNotificationState.instance.markRead(
      accountId: 1,
      sessionGeneration: 0,
      notificationId: 11,
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );
    expect(find.text('1 条新回复'), findsOneWidget);
    await _disposeFeed(tester, page);
  });

  testWidgets('不同账号或旧会话的回复事件不会清空当前首页提醒', (tester) async {
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [_unreadReply(11)],
    );
    await _pumpFrames(tester);

    ReplyNotificationState.instance.markRead(
      accountId: 2,
      sessionGeneration: 0,
      notificationId: 11,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );

    page.auth.advanceSession();
    ReplyNotificationState.instance.markRead(
      accountId: 1,
      sessionGeneration: 0,
      notificationId: 11,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );

    ReplyNotificationState.instance.markRead(
      accountId: 1,
      sessionGeneration: 1,
      notificationId: 11,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsNothing,
    );
    await _disposeFeed(tester, page);
  });

  testWidgets('未读回复并发请求只接受最后一次响应', (tester) async {
    final firstRequest = Completer<void>();
    final secondRequest = Completer<void>();
    final unreadRequestIndices = <int>[];
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItemsByRequest: [
        [_unreadReply(11)],
        [_unreadReply(11)],
        [_unreadReply(11)],
        [_unreadReply(11)],
        [_unreadReply(11), _unreadReply(12)],
      ],
      unreadRequestGatesByIndex: {
        3: firstRequest,
        4: secondRequest,
      },
      onUnreadRequest: unreadRequestIndices.add,
    );
    await _pumpFrames(tester, count: 2);

    ReplyNotificationState.instance.requestRefresh(
      accountId: 1,
      sessionGeneration: 0,
    );
    ReplyNotificationState.instance.requestRefresh(
      accountId: 1,
      sessionGeneration: 0,
    );
    await _pumpFrames(tester, count: 2);
    expect(unreadRequestIndices, containsAll([3, 4]));
    secondRequest.complete();
    await _pumpFrames(tester);
    expect(find.text('2 条新回复'), findsOneWidget);

    firstRequest.complete();
    await _pumpFrames(tester);
    expect(find.text('2 条新回复'), findsOneWidget);
    await _disposeFeed(tester, page);
  });

  testWidgets('全部已读成功后首页提醒立即消失', (tester) async {
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [_unreadReply(11), _unreadReply(12)],
      notificationItems: [_notification(11), _notification(12)],
    );
    await _pumpFrames(tester);

    unawaited(
      Navigator.of(tester.element(find.byType(ShuitieScreen))).push(
        MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('全部已读'));
    await tester.pump();
    Navigator.of(tester.element(find.byType(NotificationsScreen))).pop();
    await _pumpFrames(tester);

    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsNothing,
    );
    await _disposeFeed(tester, page);
  });

  testWidgets('通知中心标记已读失败时不伪装已读，首页仍保留提醒', (tester) async {
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [_unreadReply(11)],
      notificationItems: [_notification(11)],
      readSelectedRequestFail: true,
    );
    await _pumpFrames(tester);

    unawaited(
      Navigator.of(tester.element(find.byType(ShuitieScreen))).push(
        MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('通知中心测试回复'));
    await _pumpFrames(tester);

    expect(find.text('标记已读失败，请重试'), findsOneWidget);
    Navigator.of(tester.element(find.byType(NotificationsScreen))).pop();
    await _pumpFrames(tester);
    expect(find.byKey(const ValueKey('home-reply-notification-reminder')),
        findsOneWidget);
    expect(find.text('1 条新回复'), findsOneWidget);
    await _disposeFeed(tester, page);
  });

  testWidgets('切换会话后旧的已读请求成功也不会广播到新会话', (tester) async {
    final readSelectedGate = Completer<void>();
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [_unreadReply(11)],
      notificationItems: [_notification(11)],
      readSelectedGate: readSelectedGate,
    );
    await _pumpFrames(tester);

    unawaited(
      Navigator.of(tester.element(find.byType(ShuitieScreen))).push(
        MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
      ),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('通知中心测试回复'));
    await tester.pump();
    final versionBeforeCompletion = ReplyNotificationState.instance.version;

    page.auth.advanceSession();
    readSelectedGate.complete();
    await _pumpFrames(tester);

    expect(
      ReplyNotificationState.instance.version,
      versionBeforeCompletion,
    );
    Navigator.of(tester.element(find.byType(NotificationsScreen))).pop();
    await _pumpFrames(tester);
    expect(
      find.byKey(const ValueKey('home-reply-notification-reminder')),
      findsOneWidget,
    );
    await _disposeFeed(tester, page);
  });

  testWidgets('通知点击进行中再次点击不会重复提交已读请求', (tester) async {
    final readSelectedGate = Completer<void>();
    final markedReadIds = <int>[];
    final page = await _pumpFeed(
      tester,
      loggedIn: true,
      unreadItems: [_unreadReply(11)],
      notificationItems: [_notification(11)],
      readSelectedGate: readSelectedGate,
      onMarkRead: markedReadIds.addAll,
    );
    await _pumpFrames(tester);

    unawaited(
      Navigator.of(tester.element(find.byType(ShuitieScreen))).push(
        MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
      ),
    );
    await _pumpFrames(tester);
    final notification = find.text('通知中心测试回复');
    await tester.tap(notification);
    await tester.pump();
    await tester.tap(notification);
    await tester.pump();

    readSelectedGate.complete();
    await _pumpFrames(tester);
    expect(markedReadIds, [11]);
    await _disposeFeed(tester, page);
  });
}

Map<String, dynamic> _unreadReply(int id) => {
      'id': id,
      'post_id': 100 + id,
      'related_id': 500 + id,
      'content': '首页测试回复$id',
      'post_title': '首页测试帖子$id',
      'created_at': '2026-08-18T10:00:00Z',
      'from_user': {'id': 2, 'nickname': '回复者$id', 'avatar': ''},
    };

Map<String, dynamic> _notification(int id) => {
      'id': id,
      'type': 'reply',
      'is_read': false,
      'post_id': null,
      'related_id': null,
      'content': '通知中心测试回复',
      'created_at': '2026-08-18T10:00:00Z',
      'from_user': {'id': 2, 'nickname': '通知回复者', 'avatar': ''},
    };

Future<_FeedTestPage> _pumpFeed(
  WidgetTester tester, {
  Completer<void>? gate,
  bool fail = false,
  bool loggedIn = false,
  bool unreadRequestFail = false,
  bool Function()? unreadFailCondition,
  int? post404Id,
  void Function(List<int> ids)? onMarkRead,
  bool readSelectedRequestFail = false,
  Completer<void>? readSelectedGate,
  List<Map<String, dynamic>> notificationItems = const [],
  List<Map<String, dynamic>> unreadItems = const [],
  List<List<Map<String, dynamic>>>? unreadItemsByRequest,
  Map<int, Completer<void>>? unreadRequestGatesByIndex,
  void Function(int requestIndex)? onUnreadRequest,
}) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dio = Dio();
  var unreadRequestIndex = 0;
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
          final requestIndex = unreadRequestIndex++;
          onUnreadRequest?.call(requestIndex);
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
          final requestGate = unreadRequestGatesByIndex?[requestIndex];
          if (requestGate != null) await requestGate.future;
          final responseItems = unreadItemsByRequest != null &&
                  requestIndex < unreadItemsByRequest.length
              ? unreadItemsByRequest[requestIndex]
              : unreadItems;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'count': responseItems.length,
                'items': responseItems,
              },
            ),
          );
          return;
        }
        if (options.path == '/notifications') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: notificationItems,
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
          if (readSelectedGate != null) await readSelectedGate.future;
          if (readSelectedRequestFail) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 500,
                  data: {'error': 'failed'},
                ),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
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
