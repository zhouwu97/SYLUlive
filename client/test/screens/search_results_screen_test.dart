import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/search_results_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _SearchAuth extends ChangeNotifier implements AuthProvider {
  _SearchAuth(this.dio);

  @override
  final Dio dio;
  @override
  int sessionGeneration = 0;
  @override
  User? user;
  @override
  bool get isLoggedIn => user != null;

  void changeAccount() {
    sessionGeneration++;
    user = User(
      id: sessionGeneration,
      studentId: '',
      nickname: '测试账号',
      createdAt: DateTime(2026),
    );
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SearchTheme extends ChangeNotifier implements ThemeProvider {
  @override
  bool get shouldShowCustomBackground => false;
  @override
  bool get isCleanBackgroundMode => true;
  @override
  bool get frostedGlass => false;
  @override
  double get componentOpacity => 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PendingSearch {
  _PendingSearch(this.options, this.handler);
  final RequestOptions options;
  final RequestInterceptorHandler handler;

  void complete(List<Map<String, dynamic>> items, {int? total}) {
    handler.resolve(Response<dynamic>(
      requestOptions: options,
      statusCode: 200,
      data: {'items': items, 'total': total ?? items.length},
    ));
  }

  void fail({int? status, String? message}) {
    handler.reject(DioException(
      requestOptions: options,
      type: status == null
          ? DioExceptionType.connectionError
          : DioExceptionType.badResponse,
      response: status == null
          ? null
          : Response<dynamic>(
              requestOptions: options,
              statusCode: status,
              data: message == null ? null : {'error': message},
            ),
    ));
  }
}

class _Harness {
  final requests = <_PendingSearch>[];
  late final Dio dio = Dio(BaseOptions(baseUrl: 'https://search.test/api'))
    ..interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests.add(_PendingSearch(options, handler));
    }));
  late final auth = _SearchAuth(dio);
  final theme = _SearchTheme();

  Future<void> pump(
    WidgetTester tester, {
    String query = '测试',
    ThemeMode themeMode = ThemeMode.light,
    TextScaler textScaler = TextScaler.noScaling,
    Size viewport = GoldenViewports.phone360x800,
  }) async {
    await setGoldenViewport(tester, viewport);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<ThemeProvider>.value(value: theme),
        ChangeNotifierProvider(create: (_) => WaterSectionProvider(null)),
      ],
      child: GoldenTestApp(
        themeMode: themeMode,
        textScaler: textScaler,
        home: SearchResultsScreen(query: query),
      ),
    ));
    await flush(tester);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    dio.close(force: true);
    auth.dispose();
    theme.dispose();
    await tester.pump();
  }
}

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> submit(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await flush(tester);
}

Map<String, dynamic> post(int id, String title) => {
      'id': id,
      'title': title,
      'content': '搜索回归测试正文',
      'board_id': 1,
      'author_id': 101,
      'created_at': '2026-10-23T00:00:00Z',
      'images': <dynamic>[],
    };

Map<String, dynamic> user(int id, String nickname) => {
      'id': id,
      'nickname': nickname,
      'created_at': '2026-10-23T00:00:00Z',
    };

void main() {
  setUpAll(loadTestFonts);

  for (final query in ['', '%%', '_?*\\', '测' * 65]) {
    testWidgets('invalid query is explained without a request: "$query"',
        (tester) async {
      final h = _Harness();
      await h.pump(tester, query: query);
      expect(h.requests, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('修改关键词'), findsOneWidget);
      expect(find.textContaining('检查网络'), findsNothing);
      await h.dispose(tester);
    });
  }

  for (final query in ['2', '好', 'a', '😀']) {
    testWidgets('single character "$query" searches posts and users',
        (tester) async {
      final h = _Harness();
      await h.pump(tester, query: query);
      expect(h.requests.single.options.queryParameters['q'], query);
      h.requests.single.complete([post(1, '单字符匹配帖子')]);
      await flush(tester);
      expect(find.text('单字符匹配帖子'), findsOneWidget);
      await tester.tap(find.text('用户'));
      await flush(tester);
      expect(h.requests.last.options.queryParameters['q'], query);
      expect(h.requests.last.options.queryParameters['type'], 'users');
      h.requests.last.complete([user(2, '单字符匹配用户')]);
      await flush(tester);
      expect(find.text('单字符匹配用户'), findsOneWidget);
      expect(find.text('修改关键词'), findsNothing);
      await h.dispose(tester);
    });
  }

  testWidgets('loading, empty results and a corrected query remain usable',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(h.requests.single.options.queryParameters['board'], 1);
    expect(
        h.requests.single.options.queryParameters['capabilities'], 'poll_v1');
    h.requests.single.complete([]);
    await flush(tester);
    expect(find.text('没有找到相关帖子'), findsOneWidget);
    await submit(tester, '22');
    h.requests.last.complete([post(1, '匹配帖子')]);
    await flush(tester);
    expect(find.text('匹配帖子'), findsOneWidget);
    expect(find.text('找到 1 条结果'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('invalid input can focus the field and recover', (tester) async {
    final h = _Harness();
    await h.pump(tester, query: '');
    await tester.tap(find.text('修改关键词'));
    await flush(tester);
    expect(tester.testTextInput.isVisible, isTrue);
    await submit(tester, '22');
    expect(h.requests, hasLength(1));
    h.requests.single.complete([]);
    await flush(tester);
    expect(find.text('没有找到相关帖子'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('Unicode length uses code points and trims whitespace',
      (tester) async {
    final h = _Harness();
    final query = '😀' * 64;
    await h.pump(tester, query: '  $query  ');
    expect(h.requests.single.options.queryParameters['q'], query);
    h.requests.single.complete([]);
    await flush(tester);
    await h.dispose(tester);
  });

  for (final (status, message) in [
    (400, '搜索内容需为 1 至 64 个字符，不能只包含通配符'),
    (403, '没有权限访问搜索'),
    (429, '搜索过于频繁，请稍后再试'),
    (500, '搜索帖子失败'),
  ]) {
    testWidgets('HTTP $status shows the server reason', (tester) async {
      final h = _Harness();
      await h.pump(tester);
      h.requests.single.fail(status: status, message: message);
      await flush(tester);
      expect(find.text(message), findsOneWidget);
      expect(find.text('搜索失败，请检查网络后重试'), findsNothing);
      await h.dispose(tester);
    });
  }

  testWidgets('offline error can retry successfully', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    h.requests.single.fail();
    await flush(tester);
    expect(find.textContaining('无法连接'), findsOneWidget);
    await tester.tap(find.text('重新搜索'));
    await flush(tester);
    expect(h.requests, hasLength(2));
    h.requests.last.complete([post(1, '重试成功')]);
    await flush(tester);
    expect(find.text('重试成功'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('new query ignores an older successful response', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    final old = h.requests.single;
    await submit(tester, '新的');
    h.requests.last.complete([post(2, '新查询结果')]);
    await flush(tester);
    old.complete([post(1, '旧查询结果')]);
    await flush(tester);
    expect(find.text('新查询结果'), findsOneWidget);
    expect(find.text('旧查询结果'), findsNothing);
    await h.dispose(tester);
  });

  testWidgets('changing type ignores the old posts response', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    final old = h.requests.single;
    await tester.tap(find.text('用户'));
    await flush(tester);
    expect(h.requests.last.options.queryParameters['type'], 'users');
    expect(
        h.requests.last.options.queryParameters.containsKey('board'), isFalse);
    h.requests.last.complete([user(8, '当前用户结果')]);
    await flush(tester);
    old.complete([post(1, '过期帖子')]);
    await flush(tester);
    expect(find.text('当前用户结果'), findsOneWidget);
    expect(find.text('用户1'), findsNothing);
    expect(find.text('找到 1 条结果'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('changing sort ignores an old failure', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    final old = h.requests.single;
    await tester.tap(find.text('最新'));
    await flush(tester);
    expect(h.requests.last.options.queryParameters['sort'], 'latest');
    h.requests.last.complete([]);
    await flush(tester);
    old.fail(status: 500, message: '过期请求错误');
    await flush(tester);
    expect(find.text('没有找到相关帖子'), findsOneWidget);
    expect(find.text('过期请求错误'), findsNothing);
    await h.dispose(tester);
  });

  testWidgets('account change clears results and rejects old requests',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);
    final old = h.requests.single;
    h.auth.changeAccount();
    await flush(tester);
    expect(h.requests, hasLength(2));
    h.requests.last.complete([post(2, '当前账号结果')]);
    await flush(tester);
    old.complete([post(1, '旧账号结果')]);
    await flush(tester);
    expect(find.text('当前账号结果'), findsOneWidget);
    expect(find.text('旧账号结果'), findsNothing);
    await h.dispose(tester);
  });

  testWidgets('pagination failure preserves results and offers explicit retry',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);
    h.requests.single.complete([post(1, '首屏结果')], total: 2);
    await flush(tester);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -500));
    await flush(tester);
    expect(h.requests.last.options.queryParameters['page'], 2);
    h.requests.last.fail(status: 500, message: '下一页暂时不可用');
    await flush(tester);
    expect(find.text('首屏结果'), findsOneWidget);
    expect(find.text('下一页暂时不可用'), findsOneWidget);
    final count = h.requests.length;
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -100));
    await flush(tester);
    expect(h.requests, hasLength(count));
    await tester.tap(find.text('重试加载更多'));
    await flush(tester);
    expect(h.requests.last.options.queryParameters['page'], 2);
    h.requests.last.complete([post(2, '第二页结果')], total: 2);
    await flush(tester);
    expect(find.text('第二页结果'), findsOneWidget);
    expect(find.text('已显示全部结果'), findsOneWidget);
    await h.dispose(tester);
  });

  testWidgets('returning while loading does not update a disposed screen',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);
    final pending = h.requests.single;
    await h.dispose(tester);
    pending.complete([]);
    await flush(tester);
    expect(tester.takeException(), isNull);
  });

  for (final (mode, scale, size) in [
    (ThemeMode.light, 1.0, GoldenViewports.phone360x800),
    (ThemeMode.light, 1.0, GoldenViewports.phone390x844),
    (ThemeMode.dark, 1.0, GoldenViewports.phone360x800),
    (ThemeMode.light, 1.3, GoldenViewports.phone360x800),
  ]) {
    testWidgets('error layout remains usable at $mode $scale $size',
        (tester) async {
      final h = _Harness();
      await h.pump(tester,
          query: '',
          themeMode: mode,
          textScaler: TextScaler.linear(scale),
          viewport: size);
      expect(find.text('修改关键词'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await h.dispose(tester);
    });
  }
}
