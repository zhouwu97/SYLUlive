import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/notifications_screen.dart';

class _Auth extends ChangeNotifier implements AuthProvider {
  _Auth(this.dio);

  @override
  final Dio dio;

  @override
  int accountSessionEpoch = 0;

  int accountId = 1;

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
