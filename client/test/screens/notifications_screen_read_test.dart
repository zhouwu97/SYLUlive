import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/notifications_screen.dart';
import 'package:shenliyuan/services/reply_notification_state.dart';
import 'package:shenliyuan/features/theme_pack/admin_theme_review_screen.dart';
import 'package:shenliyuan/features/theme_pack/theme_submission_screen.dart';

class _Auth extends ChangeNotifier implements AuthProvider {
  _Auth(this.dio);

  @override
  final Dio dio;

  @override
  int accountSessionEpoch = 0;

  int accountId = 1;
  String role = 'user';

  void switchAccount(int id) {
    accountId = id;
    accountSessionEpoch++;
    notifyListeners();
  }

  @override
  int get sessionGeneration => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  bool get isLoggedIn => true;

  @override
  User get user => User(
      id: accountId,
      studentId: '',
      nickname: '测试账号',
      role: role,
      createdAt: DateTime(2026));
}

Map<String, dynamic> _notificationPage(
        {bool isRead = false, int id = 11, String content = '测试回复'}) =>
    {
      'items': [
        {
          'id': id,
          'type': 'reply',
          'is_read': isRead,
          'content': content,
          'created_at': '2026-10-19T01:00:00Z',
          'post_id': 100,
          'related_id': 200,
        },
      ],
      'has_more': false,
    };

Widget _app(Dio dio, {_Auth? auth}) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => auth ?? _Auth(dio)),
        ChangeNotifierProvider(
            create: (_) => ThemeProvider(loadOnStart: false)),
      ],
      child: const MaterialApp(home: NotificationsScreen()),
    );

Future<void> _pumpUntilRequest(
    WidgetTester tester, bool Function() arrived) async {
  // Dio 的请求拦截器在独立事件队列执行；按钮状态会先于请求进入拦截器。
  // 等待可观测的请求边界，不能用单帧 pump 假设网络流程已开始。
  for (var frame = 0; frame < 20 && !arrived(); frame++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(arrived(), isTrue, reason: '预期的已读/刷新请求未进入拦截器');
}

void main() {
  testWidgets('首屏均已读时按账号未读总数显示全部已读，无需翻页', (tester) async {
    var count = 10;
    var writes = 0;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        Object data;
        if (o.path == '/user/notifications/unread_count') {
          data = {'count': count};
        } else if (o.path == '/notifications/read') {
          count = 0;
          writes++;
          data = {};
        } else {
          expect(o.queryParameters.containsKey('cursor'), isFalse);
          data = {
            ..._notificationPage(isRead: true),
            'has_more': true,
            'next_cursor': 'older'
          };
        }
        h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
      }));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部已读'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.text('全部已读'), findsNothing);
  });

  testWidgets('切号后忽略旧账号返回的跨页未读数', (tester) async {
    final dio = Dio();
    final auth = _Auth(dio);
    RequestInterceptorHandler? oldHandler;
    RequestOptions? oldOptions;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      if (o.path == '/user/notifications/unread_count') {
        oldHandler = h;
        oldOptions = o;
        return;
      }
      h.resolve(Response(requestOptions: o, statusCode: 200, data: {
        ..._notificationPage(isRead: true),
        if (auth.accountId == 1) ...{'has_more': true, 'next_cursor': 'older'},
      }));
    }));
    await tester.pumpWidget(_app(dio, auth: auth));
    await _pumpUntilRequest(tester, () => oldHandler != null);
    auth.switchAccount(2);
    await tester.pumpAndSettle();
    oldHandler!.resolve(Response(
        requestOptions: oldOptions!, statusCode: 200, data: {'count': 10}));
    await tester.pumpAndSettle();
    expect(find.text('全部已读'), findsNothing);
  });

  for (final pushed in [true, false]) {
    testWidgets('留在空通知页时${pushed ? "收到回复推送" : "未启用推送"}也能发现新未读', (tester) async {
      var arrived = false;
      var counts = 0;
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          final isCount = o.path == '/user/notifications/unread_count';
          if (isCount) counts++;
          final data = isCount
              ? {'count': arrived ? 1 : 0}
              : arrived
                  ? _notificationPage(content: '新到的回复')
                  : {'items': [], 'has_more': false};
          h.resolve(Response(requestOptions: o, statusCode: 200, data: data));
        }));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(_app(dio));
      await tester.pumpAndSettle();
      expect(find.text('全部已读'), findsNothing);
      arrived = true;
      if (pushed) {
        ReplyNotificationState.instance
            .requestRefresh(accountId: 2, sessionGeneration: 0);
        await tester.pump();
        expect(counts, 0);
        ReplyNotificationState.instance
            .requestRefresh(accountId: 1, sessionGeneration: 0);
      } else {
        await tester.pump(const Duration(seconds: 30));
      }
      await tester.pumpAndSettle();
      expect(find.text('全部已读'), findsOneWidget);
      expect(find.text('新到的回复'), findsOneWidget);
    });
  }

  for (final type in ['theme_pending', 'theme_review']) {
    testWidgets('$type 通知显示主题提示、完整原因并打开对应列表', (tester) async {
      const channel = MethodChannel('shenliyuan/notification_open');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final dio = Dio();
      final auth = _Auth(dio)..role = type == 'theme_pending' ? 'admin' : 'user';
      final paths = <String>[];
      final content = type == 'theme_pending'
          ? '有新的主题上线申请：《海盐》v1，请前往主题审核处理'
          : '你的主题《海盐》v1 未通过审核：图片质量不达标：页头文字被背景遮挡，请修改';
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        paths.add(request.path);
        handler.resolve(Response(
          requestOptions: request,
          statusCode: 200,
          data: request.path == '/notifications'
              ? {
                  'items': [
                    {'id': 11, 'type': type, 'content': content, 'is_read': false,
                     'created_at': '2026-11-24T01:00:00Z', 'post_id': 0, 'related_id': 0},
                  ],
                  'has_more': false,
                }
              : {'items': []},
        ));
      }));
      await tester.pumpWidget(_app(dio, auth: auth));
      await tester.pumpAndSettle();
      expect(find.text(type == 'theme_pending' ? '主题上线申请待审核' : '主题审核结果'), findsOneWidget);
      expect(tester.widget<Text>(find.text(content)).maxLines, isNull);
      await tester.tap(find.text(content));
      await _pumpUntilRequest(tester, () => paths.contains(type == 'theme_pending' ? '/admin/themes' : '/themes/submissions'));
      await tester.pumpAndSettle();
      expect(paths, contains('/notifications/read-selected'));
      expect(find.byType(type == 'theme_pending' ? AdminThemeReviewScreen : MyThemeSubmissionsScreen), findsOneWidget);
      expect(paths, contains(type == 'theme_pending' ? '/admin/themes' : '/themes/submissions'));
      expect(paths.where((path) => path.startsWith('/posts/')), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final switchAccount in [false, true]) {
    testWidgets('主题待审通知等待已读期间${switchAccount ? '切号' : '降权'}不能打开审核页', (tester) async {
      const channel = MethodChannel('shenliyuan/notification_open');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final dio = Dio();
      final auth = _Auth(dio)..role = 'admin';
      RequestOptions? readRequest;
      RequestInterceptorHandler? readHandler;
      var adminRequests = 0;
      dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
        if (request.path == '/notifications/read-selected') {
          readRequest = request;
          readHandler = handler;
          return;
        }
        if (request.path == '/admin/themes') adminRequests++;
        handler.resolve(Response(requestOptions: request, statusCode: 200, data: {
          'items': auth.accountId == 1 ? [
            {'id': 11, 'type': 'theme_pending', 'is_read': false, 'content': '等待审核的主题',
             'created_at': '2026-11-24T01:00:00Z', 'post_id': 0, 'related_id': 0},
          ] : [],
          'has_more': false,
        }));
      }));
      await tester.pumpWidget(_app(dio, auth: auth));
      await tester.pumpAndSettle();
      await tester.tap(find.text('等待审核的主题'));
      await _pumpUntilRequest(tester, () => readHandler != null);
      if (switchAccount) {
        auth.switchAccount(2);
      } else {
        auth.role = 'user';
      }
      readHandler!.resolve(Response(requestOptions: readRequest!, statusCode: 200));
      await tester.pumpAndSettle();
      expect(find.byType(AdminThemeReviewScreen), findsNothing);
      expect(adminRequests, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('历史工单通知打开会话后刷新整组，不提前消费单条提醒', (tester) async {
    final dio = Dio();
    var opened = false;
    var individualReads = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      Object data;
      if (request.path == '/feedback/tickets/200') {
        opened = true;
        data = {
          'ticket': {'id': 200, 'title': '同一工单', 'status': 'pending'},
          'messages': [], 'history': [],
        };
      } else if (request.path == '/notifications/read-selected') {
        individualReads++;
        data = {};
      } else {
        data = {
          'items': opened ? [] : [
            for (var i = 1; i <= 2; i++) {
              'id': i, 'type': 'feedback_update', 'related_id': 200,
              'content': '工单新消息$i', 'is_read': false,
              'created_at': '2026-11-24T01:00:00Z',
            },
          ],
          'has_more': false,
        };
      }
      handler.resolve(Response(requestOptions: request, statusCode: 200, data: data));
    }));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工单新消息1'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(individualReads, 0);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('工单新消息1'), findsNothing);
    expect(find.text('工单新消息2'), findsNothing);
    expect(find.text('全部已读'), findsNothing);
  });

  testWidgets('被 @ 的回复通知标题显示为“@了你”并去掉正文前缀', (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      handler.resolve(Response(
          requestOptions: request,
          statusCode: 200,
          data: _notificationPage(content: '@了你：一起早八')));
    }));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();
    expect(find.text('@了你'), findsOneWidget);
    expect(find.text('一起早八'), findsOneWidget);
    expect(find.text('回复了您的帖子'), findsNothing);
  });
  testWidgets('切号清除旧列表，旧已读响应不干扰新账号的在途操作', (tester) async {
    final dio = Dio();
    final auth = _Auth(dio);
    final handlers = <RequestInterceptorHandler>[];
    final options = <RequestOptions>[];
    var accountBRead = false;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (request, handler) {
      if (request.path == '/notifications/read') {
        options.add(request);
        handlers.add(handler);
      } else {
        handler.resolve(Response(
            requestOptions: request,
            statusCode: 200,
            data: _notificationPage(
                id: auth.accountId * 10,
                content: '账号${auth.accountId}的回复',
                isRead: auth.accountId == 2 && accountBRead)));
      }
    }));
    await tester.pumpWidget(_app(dio, auth: auth));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部已读'));
    await _pumpUntilRequest(tester, () => handlers.length == 1);
    auth.switchAccount(2);
    await tester.pumpAndSettle();
    expect(find.text('账号1的回复'), findsNothing);
    expect(find.text('账号2的回复'), findsOneWidget);
    await tester.tap(find.text('全部已读'));
    await _pumpUntilRequest(tester, () => handlers.length == 2);
    expect(options[0].extra, containsPair('expectedAuthUserId', 1));
    expect(options[1].extra, containsPair('expectedAuthUserId', 2));
    handlers[0].resolve(Response(requestOptions: options[0], statusCode: 200));
    await tester.pumpAndSettle();
    expect(find.text('处理中…'), findsOneWidget);
    expect(find.text('账号2的回复'), findsOneWidget);
    accountBRead = true;
    handlers[1].resolve(Response(requestOptions: options[1], statusCode: 200));
    await tester.pumpAndSettle();
    expect(find.text('全部已读'), findsNothing);
  });
  testWidgets('批量已读完成后校准，新到达的通知继续保留未读', (tester) async {
    final dio = Dio();
    var gets = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/notifications/read') {
        expect(options.extra, containsPair('expectedAuthUserId', 1));
        expect(options.extra, containsPair('expectedAuthSessionEpoch', 0));
        handler.resolve(Response(requestOptions: options, statusCode: 200));
      } else {
        gets++;
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: gets == 1
                ? _notificationPage()
                : _notificationPage(id: 12, content: '批量更新之后的新回复')));
      }
    }));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部已读'));
    await tester.pumpAndSettle();
    expect(gets, 2);
    expect(find.text('批量更新之后的新回复'), findsOneWidget);
    expect(find.text('全部已读'), findsOneWidget);
  });
  testWidgets('全部已读防重复提交，迟到的刷新响应不能恢复红点', (tester) async {
    final dio = Dio();
    RequestInterceptorHandler? refreshHandler;
    RequestOptions? refreshOptions;
    RequestInterceptorHandler? readHandler;
    RequestOptions? readOptions;
    var reads = 0;
    var gets = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/notifications') {
        if (++gets == 1) {
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: _notificationPage()));
        } else if (gets == 2) {
          refreshHandler = handler;
          refreshOptions = options;
        } else {
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: _notificationPage(isRead: true)));
        }
      } else if (options.path == '/notifications/read') {
        reads++;
        readHandler = handler;
        readOptions = options;
      } else {
        handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: {}));
      }
    }));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();
    final refreshing = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await _pumpUntilRequest(tester, () => refreshHandler != null);
    await tester.tap(find.text('全部已读'));
    await _pumpUntilRequest(tester, () => reads == 1);
    expect(find.text('处理中…'), findsOneWidget);
    expect(reads, 1);
    expect(
        tester
            .widget<TextButton>(find.ancestor(
                of: find.text('处理中…'), matching: find.byType(TextButton)))
            .onPressed,
        isNull);
    readHandler!
        .resolve(Response(requestOptions: readOptions!, statusCode: 200));
    await tester.pumpAndSettle();
    expect(find.text('全部已读'), findsNothing);
    refreshHandler!.resolve(Response(
        requestOptions: refreshOptions!,
        statusCode: 200,
        data: _notificationPage()));
    await refreshing;
    await tester.pumpAndSettle();
    expect(find.text('全部已读'), findsNothing);
    expect(find.text('测试回复'), findsOneWidget);
  });

  testWidgets('全部已读失败保留未读状态并允许重试', (tester) async {
    final dio = Dio();
    var attempts = 0;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.path == '/notifications/read') {
        if (++attempts == 1) {
          handler.reject(DioException(
              requestOptions: options, type: DioExceptionType.connectionError));
        } else {
          handler.resolve(Response(requestOptions: options, statusCode: 200));
        }
      } else {
        handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: _notificationPage(isRead: attempts > 1)));
      }
    }));
    await tester.pumpWidget(_app(dio));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部已读'));
    await tester.pumpAndSettle();
    expect(find.text('全部已读'), findsOneWidget);
    expect(find.text('操作失败'), findsOneWidget);
    await tester.tap(find.text('全部已读'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('全部已读'), findsNothing);
  });
}
