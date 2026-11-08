import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/course_evaluation_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/social_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/teacher_provider.dart';
import 'package:shenliyuan/screens/my_content_screen.dart';
import 'package:shenliyuan/services/poll_service.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Map<String, dynamic> _post(int id,
        {int author = 20,
        bool market = true,
        String type = 'sell',
        String status = 'normal'}) =>
    {
      'id': id,
      'author_id': author,
      'board_id': market ? 2 : 1,
      'title': '${market ? '商品' : '帖子'} $id',
      'content': '本地测试内容',
      'post_type': market ? type : 'normal',
      'status': status,
      'price': 80,
      'created_at': '2026-11-04T00:00:00Z',
    };

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  List<Map<String, dynamic>> posts = [];
  List<Map<String, dynamic>> market = [_post(201), _post(202)];
  int marketStatus = 200;
  bool holdMarket = false;
  Map<String, dynamic> evaluationPage = {};
  final pending = <Completer<ResponseBody>>[];

  @override
  void close({bool force = false}) {}

  ResponseBody response(Object data, [int status = 200]) =>
      ResponseBody.fromString(jsonEncode(data), status, headers: {
        Headers.contentTypeHeader: ['application/json']
      });

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.path == '/user/canteen-reviews') {
      return response({'items': [], 'has_more': false});
    }
    if (options.path == '/user/course-evaluations') {
      return response(evaluationPage);
    }
    if (options.path == '/teachers/7') {
      return response({
        'teacher': {'id': 7, 'name': '朱俊', 'course': '气排球文化与健康'},
        'ratings': [],
        'my_rating': {
          'id': 1,
          'teacher_id': 7,
          'user_id': 20,
          'star': 5,
          'comment': '本人的教师评价',
          'status': 'normal',
          'created_at': '2026-11-04T00:00:00Z'
        },
        'rating_count': 1,
        'average_star': 5,
      });
    }
    final isMarket = options.path.endsWith('/market-posts');
    if (isMarket && holdMarket) {
      final gate = Completer<ResponseBody>();
      pending.add(gate);
      return gate.future;
    }
    if (isMarket && marketStatus != 200) {
      return response({'error': '本地接口失败'}, marketStatus);
    }
    if (isMarket || options.path.endsWith('/posts')) {
      final items = isMarket ? market : posts;
      final page = options.queryParameters['page'] as int? ?? 1;
      final limit = options.queryParameters['limit'] as int? ?? 20;
      final batch = items.skip((page - 1) * limit).take(limit).toList();
      return response(isMarket
          ? {'items': batch, 'total': items.length, 'sold': 0}
          : batch);
    }
    return response({});
  }
}

class _MemoryCredentials implements AuthCredentialStore {
  @override
  Future<void> clear() async {}
  @override
  Future<StoredAuthCredentials> read() async => const StoredAuthCredentials();
  @override
  Future<void> write({required String token, required String userJson}) async {}
}

class _Harness {
  final _Adapter adapter;
  late final Dio dio;
  late final AuthProvider auth;
  late final SocialProvider social;
  late final CourseEvaluationProvider evaluations;
  late final PostProvider posts;
  late final PollProvider polls;
  final theme = ThemeProvider(loadOnStart: false);

  _Harness(this.adapter) {
    dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    auth = AuthProvider(dio,
        credentialStore: _MemoryCredentials(),
        loadStoredAuth: false,
        onAuthenticated: () {});
    social = SocialProvider(dio);
    evaluations = CourseEvaluationProvider(dio);
    posts = PostProvider(dio, enableCache: false);
    polls = PollProvider(PollService(dio), posts);
    auth.addListener(_sync);
  }

  void _sync() {
    social.syncSessionUser(auth.user?.id);
    evaluations.syncSessionUser(auth.user?.id, auth.accountSessionEpoch);
  }

  Future<void> account(int id) => auth.applyAuthPayload('local-test-token', {
        'id': id,
        'student_id': 'local-$id',
        'nickname': '本地测试账号',
        'legal_consents_active': true,
        'legal_consents_required': false,
        'created_at': '2026-11-04T00:00:00Z',
      });

  Widget app({bool dark = false}) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider.value(value: social),
          ChangeNotifierProvider.value(value: evaluations),
          ChangeNotifierProvider.value(value: posts),
          ChangeNotifierProvider.value(value: polls),
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
          ChangeNotifierProvider(create: (_) => TeacherProvider(dio)),
        ],
        child: GoldenTestApp(
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          textScaler: TextScaler.linear(dark ? 1.3 : 1),
          home: const MyContentScreen(initialTabIndex: 1),
        ),
      );

  void dispose() {
    auth.removeListener(_sync);
    auth.dispose();
    social.dispose();
    evaluations.dispose();
    posts.dispose();
    polls.dispose();
    theme.dispose();
  }
}

Future<_Harness> _show(WidgetTester tester, _Adapter adapter,
    {bool dark = false}) async {
  await setGoldenViewport(tester, GoldenViewports.phone390x844);
  final h = _Harness(adapter);
  addTearDown(h.dispose);
  await h.account(20);
  await tester.pumpWidget(h.app(dark: dark));
  await _advance(tester);
  return h;
}

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Finder _contentTab(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Tab));

void _expectTabCount(String label, int count) {
  expect(find.descendant(of: _contentTab(label), matching: find.text('$count')),
      findsOneWidget);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'shenliyuan/keep_alive',
      'shenliyuan/grade_reminders'
    ]) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
  });

  for (final dark in [false, true]) {
    testWidgets('我的集市读取专用接口并保留全部类型和历史状态 dark=$dark', (tester) async {
      final adapter = _Adapter()
        ..posts = [_post(101, market: false)]
        ..market = [
          _post(201),
          _post(202, status: 'sold'),
          _post(203, type: 'buy', status: 'completed'),
          _post(204, type: 'lost'),
          _post(205, type: 'found'),
          _post(206, type: 'service'),
          _post(207, status: 'moderated_hidden'),
        ];
      await _show(tester, adapter, dark: dark);
      await tester.pumpAndSettle();
      _expectTabCount('我的集市', 7);
      expect(find.text('商品 201'), findsOneWidget);
      expect(find.text('暂无商品'), findsNothing);
      final marketRequest =
          adapter.requests.firstWhere((r) => r.path == '/user/20/market-posts');
      expect(marketRequest.queryParameters['post_type'], 'all');
      expect(marketRequest.queryParameters['limit'], 50);
      await tester.scrollUntilVisible(find.text('商品 207'), 250,
          scrollable: find.byType(Scrollable).last);
      expect(find.text('已被限制展示 · 仅自己与管理员可见'), findsOneWidget);
      expect(tester.takeException(), isNull);
      _expectTabCount('我的帖子', 1);
      await tester.tap(find.text('我的帖子'));
      await tester.pumpAndSettle();
      expect(find.text('帖子 101'), findsOneWidget);
      expect(find.text('商品 201'), findsNothing);
      await tester.tap(find.text('我的集市'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('商品 201'), -300,
          scrollable: find.byType(Scrollable).last);
      await tester.longPress(find.text('商品 201'));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final dark in [false, true]) {
    testWidgets('学科页两种入口共用主记录和编辑表单 dark=$dark', (tester) async {
      final adapter = _Adapter()
        ..evaluationPage = {
          'items': [
            {
              'id': 1,
              'user_id': 20,
              'source': 'schedule',
              'course_name': '马克思主义基本原理',
              'teacher_name': '周吾诠',
              'star': 1,
              'comment': '课程提交评价',
              'status': 'published'
            },
            {
              'id': 2,
              'user_id': 20,
              'source': 'legacy_teacher',
              'course_name': '气排球文化与健康',
              'teacher_name': '朱俊',
              'teacher_id': 7,
              'teacher_rating_id': 1,
              'teacher_rating_status': 'normal',
              'star': 5,
              'comment': List.filled(450, '评').join(),
              'status': 'published'
            },
          ],
          'total': 2,
          'has_more': false,
        };
      adapter.posts = List.generate(16, (i) => _post(100 + i, market: false));
      await _show(tester, adapter, dark: dark);
      await tester.pumpAndSettle();
      // 未切到第三页签前也应显示完整数量。
      _expectTabCount('学科评价', 2);
      for (final labelFinder in [
        find.text('我的帖子'),
        find.descendant(of: _contentTab('我的帖子'), matching: find.text('16')),
      ]) {
        final label = tester.renderObject<RenderParagraph>(labelFinder);
        expect(label.size.width + .5,
            greaterThanOrEqualTo(label.getMaxIntrinsicWidth(double.infinity)),
            reason: '大字号下页签名称和数量不能被裁切或淡出');
      }
      await tester.tap(find.text('学科评价'));
      await tester.pumpAndSettle();
      expect(find.text('气排球文化与健康 · 朱俊'), findsOneWidget);
      expect(find.text('马克思主义基本原理 · 周吾诠'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: '两种入口使用真实主记录 ID');
      await tester.tap(find.text('编辑').last);
      await tester.pumpAndSettle();
      expect(adapter.requests.any((r) => r.path == '/teachers/7'), isFalse);
      final commentFields = tester.widgetList<TextField>(find.byType(TextField));
      final legacyComment = commentFields.singleWhere((field) => field.controller?.text == List.filled(450, '评').join());
      expect(legacyComment.maxLength, 500);
      expect(adapter.requests.any((r) => r.method == 'PATCH'), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('服务端每页上限内继续读取，帖子与商品超过一页仍可管理', (tester) async {
    final adapter = _Adapter()
      ..posts = List.generate(51, (i) => _post(1000 + i, market: false))
      ..market = List.generate(51, (i) => _post(2000 + i));
    await _show(tester, adapter);
    await tester.pumpAndSettle();
    _expectTabCount('我的帖子', 51);
    _expectTabCount('我的集市', 51);
    final marketRequests = adapter.requests
        .where((r) => r.path.endsWith('/market-posts'))
        .toList();
    expect(marketRequests.map((r) => r.queryParameters['page']), [1, 2]);
    expect(
        adapter.requests.where((r) => r.path.endsWith('/posts')), hasLength(2));
    expect(
        adapter.requests
            .where((r) =>
                r.path.endsWith('/posts') || r.path.endsWith('/market-posts'))
            .every((r) => r.queryParameters['limit'] == 50),
        isTrue);
    await tester.scrollUntilVisible(find.text('商品 2050'), 600,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('商品 2050'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('集市请求未完成时显示加载，不显示空商品', (tester) async {
    final adapter = _Adapter()..holdMarket = true;
    await _show(tester, adapter);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('暂无商品'), findsNothing);
    adapter.pending.single.complete(adapter.response({
      'items': [_post(201)],
      'total': 1,
      'sold': 0,
    }));
    await tester.pumpAndSettle();
    expect(find.text('商品 201'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('四栏均分且加载、完成和切换时位置不变 dark=$dark', (tester) async {
      final adapter = _Adapter()
        ..holdMarket = true
        ..posts = List.generate(16, (i) => _post(100 + i, market: false));
      await _show(tester, adapter, dark: dark);
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      await tester.pump();
      const names = ['我的帖子', '我的集市', '学科评价', '食堂评价'];
      final barBefore = tester.getRect(find.byType(TabBar));
      final labelsBefore = names.map((name) => tester.getRect(find.text(name))).toList();
      for (var i = 0; i < names.length; i++) {
        final hit = tester.getRect(find.ancestor(
            of: _contentTab(names[i]), matching: find.byType(InkWell)).first);
        expect(hit.width, closeTo(barBefore.width / 4, .01));
        expect(hit.height, greaterThanOrEqualTo(44));
        expect(labelsBefore[i].center.dx,
            closeTo(barBefore.left + barBefore.width * (i + .5) / 4, .01));
      }
      adapter.pending.single.complete(adapter.response({
        'items': [_post(201), _post(202)], 'total': 2, 'sold': 0,
      }));
      await tester.pumpAndSettle();
      _expectTabCount('我的帖子', 16);
      _expectTabCount('我的集市', 2);
      expect(tester.getRect(find.byType(TabBar)), barBefore);
      for (var i = 0; i < names.length; i++) {
        expect(tester.getRect(find.text(names[i])), labelsBefore[i]);
      }
      for (var i = 0; i < names.length; i++) {
        final slot = Offset(barBefore.left + barBefore.width * (i + .5) / 4,
            barBefore.bottom - 8);
        await tester.tapAt(slot);
        await tester.pumpAndSettle();
        expect(tester.widget<TabBar>(find.byType(TabBar)).controller!.index, i);
        expect(tester.getRect(find.byType(TabBar)), barBefore);
      }
      for (final text in find.descendant(
          of: find.byType(TabBar), matching: find.byType(RichText)).evaluate()) {
        final paragraph = text.renderObject! as RenderParagraph;
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(paragraph.size.width + .5,
            greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity)));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('专用接口确认为空才显示暂无商品', (tester) async {
    await _show(tester, _Adapter()..market = []);
    await tester.pumpAndSettle();
    expect(find.text('暂无商品'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  for (final status in [403, 500]) {
    testWidgets('商品 $status 显示错误并可重试，不冒充空列表', (tester) async {
      final adapter = _Adapter()..marketStatus = status;
      await _show(tester, adapter);
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('暂无商品'), findsNothing);
      final errorTabBounds = tester.getRect(find.byType(TabBar));
      adapter.marketStatus = 200;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('商品 201'), findsOneWidget);
      expect(tester.getRect(find.byType(TabBar)), errorTabBounds);
      expect(tester.takeException(), isNull);
    });
  }

  for (final staleFails in [false, true]) {
    testWidgets('账号 A→B→A 后旧商品响应不能覆盖最新状态 staleFails=$staleFails',
        (tester) async {
      final adapter = _Adapter()..holdMarket = true;
      final h = await _show(tester, adapter);
      await tester.runAsync(() => h.account(21));
      await _advance(tester);
      await tester.runAsync(() => h.account(20));
      await _advance(tester);
      expect(adapter.pending, hasLength(3));
      adapter.pending[2].complete(adapter.response({
        'items': [_post(203)],
        'total': 1,
        'sold': 0,
      }));
      await tester.pumpAndSettle();
      expect(find.text('商品 203'), findsOneWidget);
      adapter.pending[1].complete(adapter.response({
        'items': [_post(204, author: 21)],
        'total': 1,
        'sold': 0,
      }));
      adapter.pending[0].complete(staleFails
          ? adapter.response({'error': '旧请求失败'}, 500)
          : adapter.response({
              'items': [_post(201)],
              'total': 1,
              'sold': 0
            }));
      await tester.pumpAndSettle();
      expect(find.text('商品 203'), findsOneWidget);
      expect(find.text('商品 201'), findsNothing);
      expect(find.text('商品 204'), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('离开页面后商品请求完成不触发 setState', (tester) async {
    final adapter = _Adapter()..holdMarket = true;
    await _show(tester, adapter);
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.pending.single.complete(adapter.response({
      'items': [_post(201)],
      'total': 1,
      'sold': 0,
    }));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
