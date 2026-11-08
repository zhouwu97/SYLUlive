import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/course_evaluation_provider.dart';
import 'package:shenliyuan/providers/social_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/my_content_screen.dart';
import 'package:shenliyuan/screens/my_canteen_reviews_screen.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Map<String, dynamic> _review(int id, {bool legacy = false}) => {
      'id': id,
      'canteen_id': id,
      'user_id': 20,
      'source': legacy ? 'legacy' : 'v2',
      if (legacy) 'legacy_rating_id': id,
      'overall_score': 4.5,
      'taste_score': legacy ? 0 : 5,
      'value_score': legacy ? 0 : 4,
      'queue_score': legacy ? 0 : 4,
      'hygiene_score': legacy ? 0 : 5,
      'service_score': legacy ? 0 : 4,
      'comment': '食堂记录 $id',
      'created_at': '2026-11-04T00:00:00Z',
      'can_edit': !legacy,
      'can_delete': true,
      'canteen': {
        'id': id,
        'name': '商家 $id',
        'image': '',
        'is_offline': legacy
      },
    };

class _Auth extends AuthProvider {
  _Auth(super.dio) : super(loadStoredAuth: false);
  int? account = 20;
  int epoch = 0;
  @override
  User? get user => account == null
      ? null
      : User(
          id: account!,
          studentId: 'local',
          nickname: '本地测试',
          createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => account != null;
  @override
  int get accountSessionEpoch => epoch;
  void switchAccount(int? id) {
    account = id;
    epoch++;
    notifyListeners();
  }
}

class _Adapter implements HttpClientAdapter {
  List<Map<String, dynamic>> items = [_review(1), _review(2, legacy: true)];
  int status = 200;
  bool hold = false, postsFail = false, paginated = false;
  final pending = <Completer<ResponseBody>>[];
  Completer<ResponseBody>? pendingEdit;
  final requests = <RequestOptions>[];
  ResponseBody response(Object data, [int status = 200]) =>
      ResponseBody.fromString(jsonEncode(data), status, headers: {
        Headers.contentTypeHeader: ['application/json']
      });
  ResponseBody page(List<Map<String, dynamic>> data) =>
      response({'items': data, 'has_more': false});
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
      RequestOptions o, Stream<List<int>>? stream, Future<void>? cancel) async {
    requests.add(o);
    if (o.path.endsWith('/edit-context') && pendingEdit != null) {
      return pendingEdit!.future;
    }
    if (o.path == '/user/canteen-reviews') {
      if (o.queryParameters['limit'] == 50) return page(items);
      if (hold) {
        final gate = Completer<ResponseBody>();
        pending.add(gate);
        return gate.future;
      }
      if (status != 200) return response({'error': '暂时无法读取食堂评价'}, status);
      if (paginated && o.queryParameters['cursor'] == null) {
        return response(
            {'items': items, 'has_more': true, 'next_cursor': 'second'});
      }
      return page(paginated ? [_review(30)] : items);
    }
    if (o.path == '/user/course-evaluations') {
      return response({'items': [], 'has_more': false});
    }
    if (postsFail) return response({'error': '帖子读取失败'}, 503);
    if (o.path.endsWith('/market-posts')) {
      return response({'items': [], 'total': 0});
    }
    return response([]);
  }
}

class _Harness {
  _Harness(this.adapter, {bool guest = false}) {
    dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    auth = _Auth(dio)..account = guest ? null : 20;
    evaluations = CourseEvaluationProvider(dio)
      ..syncSessionUser(auth.user?.id, auth.epoch);
    social = SocialProvider(dio)..syncSessionUser(auth.user?.id);
    auth.addListener(sync);
  }
  final _Adapter adapter;
  late final Dio dio;
  late final _Auth auth;
  late final CourseEvaluationProvider evaluations;
  late final SocialProvider social;
  final appearance = ThemeProvider(loadOnStart: false);
  void sync() {
    evaluations.syncSessionUser(auth.user?.id, auth.epoch);
    social.syncSessionUser(auth.user?.id);
  }

  Widget app({bool dark = false, bool standalone = false}) => MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider.value(value: evaluations),
          ChangeNotifierProvider.value(value: social),
          ChangeNotifierProvider.value(value: appearance),
          ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
        ],
        child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: TextScaler.linear(dark ? 1.3 : 1),
            home: standalone
                ? const MyCanteenReviewsScreen()
                : const MyContentScreen(initialTabIndex: 3)),
      );
  void dispose() {
    auth.removeListener(sync);
    auth.dispose();
    evaluations.dispose();
    social.dispose();
    appearance.dispose();
  }
}

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<_Harness> _show(WidgetTester tester, _Adapter adapter,
    {bool dark = false, bool guest = false, bool standalone = false}) async {
  await setGoldenViewport(tester,
      dark ? GoldenViewports.phone360x800 : GoldenViewports.phone390x844);
  final h = _Harness(adapter, guest: guest);
  addTearDown(h.dispose);
  await tester.pumpWidget(h.app(dark: dark, standalone: standalone));
  await _advance(tester);
  return h;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    testWidgets('第四页签显示新旧食堂评价并保留操作，dark=$dark', (tester) async {
      await _show(tester, _Adapter(), dark: dark);
      await tester.pumpAndSettle();
      final bar = tester.widget<TabBar>(find.byType(TabBar));
      expect(bar.tabs.cast<Tab>().map((t) => (t.child! as Semantics).properties.label),
          ['我的帖子', '我的集市', '学科评价', '食堂评价 (2)']);
      expect(bar.controller!.index, 3);
      expect(find.text('我的内容'), findsOneWidget);
      expect(find.text('我的菜品评价'), findsNothing);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('食堂记录 1'), findsOneWidget);
      expect(find.text('商家 2'), findsOneWidget);
      expect(find.text('已下架'), findsOneWidget);
      expect(find.text('旧版星级评价'), findsOneWidget);
      expect(find.text('味道 5'), findsOneWidget);
      expect(find.text('味道 0'), findsNothing);
      expect(find.byTooltip('我的食堂贡献'), findsOneWidget);
      await tester.tap(find.byTooltip('评价操作').first);
      await tester.pumpAndSettle();
      expect(find.text('修改这条评价'), findsOneWidget);
      expect(find.text('删除这条评价'), findsOneWidget);
      for (final element in find
          .descendant(of: find.byType(TabBar), matching: find.byType(RichText))
          .evaluate()) {
        final paragraph = element.renderObject as RenderParagraph;
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('加载时不误报空，完成后显示实际列表', (tester) async {
    final a = _Adapter()..hold = true;
    await _show(tester, a);
    expect(find.text('还没有菜品评价'), findsNothing);
    expect(find.text('食堂记录 1'), findsNothing);
    expect(a.pending, hasLength(1));
    a.pending.single.complete(a.page(a.items));
    await tester.pumpAndSettle();
    expect(find.text('食堂记录 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final status in [403, 503]) {
    testWidgets('食堂失败状态可恢复 status=$status', (tester) async {
      final a = _Adapter()..status = status;
      await _show(tester, a);
      await tester.pumpAndSettle();
      expect(find.text('重新加载'), findsOneWidget);
      expect(find.text('还没有菜品评价'), findsNothing);
      a.status = 200;
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(find.text('食堂记录 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('真实空数据保留商家入口，帖子失败不阻塞食堂', (tester) async {
    await _show(
        tester,
        _Adapter()
          ..items = []
          ..postsFail = true);
    await tester.pumpAndSettle();
    expect(find.text('还没有菜品评价'), findsOneWidget);
    expect(find.text('去看看商家'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('游客不请求个人食堂接口并提供登录入口', (tester) async {
    final a = _Adapter();
    await _show(tester, a, guest: true);
    await tester.pumpAndSettle();
    expect(find.text('登录后查看食堂评价'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    expect(find.byTooltip('我的食堂贡献'), findsNothing);
    expect(a.requests.where((o) => o.path == '/user/canteen-reviews'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('食堂分页继续读取并保留第一页', (tester) async {
    final a = _Adapter()
      ..items = List.generate(6, (i) => _review(i + 1))
      ..paginated = true;
    await _show(tester, a);
    await tester.pumpAndSettle();
    final list = find.descendant(
        of: find.byType(MyCanteenReviewsScreen),
        matching: find.byType(ListView));
    for (var i = 0;
        i < 8 &&
            !a.requests.any((o) => o.queryParameters['cursor'] == 'second');
        i++) {
      await tester.drag(list, const Offset(0, -500));
      await tester.pumpAndSettle();
    }
    expect(
        a.requests.any((o) => o.queryParameters['cursor'] == 'second'), isTrue);
    await tester.scrollUntilVisible(find.text('食堂记录 30'), 300,
        scrollable:
            find.descendant(of: list, matching: find.byType(Scrollable)).first);
    expect(find.text('食堂记录 30'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('账号 A→B→A 晚返回内容和错误不能覆盖当前列表', (tester) async {
    final a = _Adapter()..hold = true;
    final h = await _show(tester, a);
    h.auth.switchAccount(21);
    await _advance(tester);
    h.auth.switchAccount(20);
    await _advance(tester);
    expect(a.pending, hasLength(3));
    a.pending.last.complete(a.page([_review(99)]));
    await tester.pumpAndSettle();
    expect(find.text('食堂记录 99'), findsOneWidget);
    a.pending.first.complete(a.page([_review(1)]));
    a.pending[1].complete(a.response({'error': '旧账号失败'}, 500));
    await tester.pumpAndSettle();
    expect(find.text('食堂记录 99'), findsOneWidget);
    expect(find.text('食堂记录 1'), findsNothing);
    expect(find.text('重新加载'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('独立历史评价入口仍可用，离开后的返回不再刷新页面', (tester) async {
    final a = _Adapter()..hold = true;
    await _show(tester, a, standalone: true);
    expect(find.text('我的菜品评价'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    a.pending.single.complete(a.page(a.items));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换账号后旧编辑上下文返回不打开原账号编辑页', (tester) async {
    final a = _Adapter()..pendingEdit = Completer<ResponseBody>();
    final h = await _show(tester, a);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('评价操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改这条评价'));
    await _advance(tester);
    expect(a.requests.any((o) => o.path.endsWith('/edit-context')), isTrue);
    a.items = [];
    h.auth.switchAccount(21);
    await _advance(tester);
    a.pendingEdit!.complete(a.response({'review': {..._review(1), 'review_event_id': 1}}));
    await tester.pumpAndSettle();
    expect(find.text('修改食堂评价'), findsNothing);
    expect(find.text('还没有菜品评价'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除确认期间切换账号，不发送原账号删除请求', (tester) async {
    final a = _Adapter();
    final h = await _show(tester, a);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('评价操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除这条评价'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条评价？'), findsOneWidget);
    a.items = [];
    h.auth.switchAccount(21);
    await _advance(tester);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(a.requests.where((o) => o.method == 'DELETE'), isEmpty);
    expect(find.text('还没有菜品评价'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
