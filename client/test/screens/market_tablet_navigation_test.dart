import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/social_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/providers/water_moderator_provider.dart';
import 'package:shenliyuan/providers/water_moderation_provider.dart';
import 'package:shenliyuan/screens/market_screen.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/screens/user_home_screen.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/utils/app_navigator.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/widgets/market_post_card.dart';
import 'package:shenliyuan/widgets/cached_avatar.dart';

import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Map<String, dynamic> _post(int id, {bool market = true}) => {
      'id': id,
      'title': market ? '平板商品 $id' : '主页帖子 $id',
      'content': '测试内容',
      'board_id': market ? 2 : 1,
      'post_type': market ? 'sell' : 'normal',
      'price': market ? 50 : null,
      'author_id': 2,
      'author': {'id': 2, 'nickname': '商品作者'},
      'created_at': '2026-11-01T08:00:00Z',
    };

class _Adapter implements HttpClientAdapter {
  int feedStatus = 200;
  int detailStatus = 200;
  List<Map<String, dynamic>> posts = [_post(201), _post(202)];
  Completer<void>? detailGate;
  Completer<void>? feedGate;
  Completer<void>? searchGate;
  final paths = <String>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? stream,
      Future<void>? cancel) async {
    final path = options.path;
    paths.add(path);
    var status = 200;
    Object data;
    if (path == '/posts') {
      final searching = options.queryParameters['q'] != null;
      if (searching && searchGate != null) await searchGate!.future;
      if (!searching && feedGate != null) await feedGate!.future;
      status = feedStatus;
      data = {
        'posts': searching ? [_post(299)] : posts,
        'total': searching ? 1 : posts.length,
      };
    } else if (RegExp(r'^/posts/\d+$').hasMatch(path)) {
      if (detailGate != null) await detailGate!.future;
      status = detailStatus;
      final id = int.parse(path.split('/').last);
      data = status == 200 ? _post(id, market: id != 301) : {'error': '测试失败'};
    } else if (path.endsWith('/replies')) {
      data = {'replies': [], 'total': 0, 'next_cursor': ''};
    } else if (path == '/user/2') {
      data = {
        'id': 2,
        'nickname': '商品作者',
        'student_id': 'fixture2',
        'created_at': '2026-11-01T08:00:00Z',
      };
    } else if (path == '/user/2/posts') {
      data = [_post(301, market: false)];
    } else if (path == '/user/2/market-posts') {
      data = {
        'items': [_post(201)],
        'total': 1,
        'sold': 0
      };
    } else {
      data = {'count': 0};
    }
    return ResponseBody.fromString(jsonEncode(data), status, headers: {
      Headers.contentTypeHeader: ['application/json']
    });
  }
}

class _Auth extends ChangeNotifier implements AuthProvider {
  _Auth(this.dio);
  @override
  final Dio dio;
  int account = 1;
  int epoch = 0;
  String role = 'user';
  bool loggedIn = true;
  @override
  User? get user => loggedIn
      ? User(
          id: account,
          studentId: 'fixture',
          nickname: '测试用户',
          role: role,
          createdAt: DateTime(2026))
      : null;
  @override
  bool get isLoggedIn => loggedIn;
  @override
  int get accountSessionEpoch => epoch;
  @override
  int get sessionGeneration => epoch;
  void changeSession({int? id, bool? login, String? newRole}) {
    account = id ?? account;
    loggedIn = login ?? loggedIn;
    role = newRole ?? role;
    epoch++;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Harness {
  _Harness(this.adapter) {
    dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    auth = _Auth(dio);
  }
  final _Adapter adapter;
  late final Dio dio;
  late final _Auth auth;
  final root = GlobalKey<NavigatorState>();
  final theme = ThemeProvider(loadOnStart: false);

  Widget app(
          {bool profile = false,
          bool embedded = false,
          bool dark = false,
          double scale = 1}) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider(
              create: (_) => PostProvider(dio, enableCache: false)),
          ChangeNotifierProvider(create: (_) => SocialProvider(dio)),
          ChangeNotifierProvider(create: (_) => WaterSectionProvider(null)),
          ChangeNotifierProvider(create: (_) => WaterModeratorProvider(dio)),
          ChangeNotifierProvider(create: (_) => WaterModerationProvider(dio)),
        ],
        child: MaterialApp(
          navigatorKey: root,
          routes: {'/login': (_) => const Scaffold(body: Text('登录测试页'))},
          theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale), disableAnimations: true),
            child: child!,
          ),
          home: GlobalBackgroundWrapper(
              child: Row(children: [
            const SizedBox(width: 104, child: Text('侧边导航')),
            if (embedded) const SizedBox(width: 380, child: Text('左侧信息流')),
            Expanded(
                child: profile
                    ? embedded
                        ? const SharedPageBackground(
                            child: UserHomeScreen(userId: 2))
                        : const UserHomeScreen(userId: 2)
                    : const MarketScreen()),
          ])),
        ),
      );
}

Future<_Harness> _show(WidgetTester tester,
    {Size size = const Size(1280, 800),
    bool profile = false,
    bool embedded = false,
    bool dark = false,
    double scale = 1,
    _Adapter? adapter}) async {
  await setGoldenViewport(tester, size);
  final h = _Harness(adapter ?? _Adapter());
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    h.auth.dispose();
    h.theme.dispose();
  });
  await tester.pumpWidget(
      h.app(profile: profile, embedded: embedded, dark: dark, scale: scale));
  await _advance(tester);
  return h;
}

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _openProduct(WidgetTester tester, [int id = 201]) async {
  await tester.tap(find.text('平板商品 $id').first);
  await _advance(tester);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    currentHomeTabIndex.value = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => Directory.systemTemp.path);
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), null));

  testWidgets('集市商品在右栏切换、作者继续跳转及逐层返回', (tester) async {
    final h = await _show(tester);
    await _openProduct(tester);
    expect(tester.getTopLeft(find.byType(PostDetailScreen)).dx, 484);
    expect(find.text('集市'), findsOneWidget);
    expect(h.root.currentState!.canPop(), isFalse);
    await _openProduct(tester, 202);
    expect(
        tester.widget<PostDetailScreen>(find.byType(PostDetailScreen)).postId,
        202);
    tester
        .widget<PostDetailScreen>(find.byType(PostDetailScreen))
        .onAuthorTap!(2);
    await _advance(tester);
    expect(find.byType(UserHomeScreen), findsOneWidget);
    expect(tester.getTopLeft(find.byType(UserHomeScreen)).dx, 484);
    await tester.tap(find.text('主页帖子 301'));
    await _advance(tester);
    expect(
        tester.widget<PostDetailScreen>(find.byType(PostDetailScreen)).postId,
        301);
    expect(tester.getTopLeft(find.byType(PostDetailScreen)).dx, 484);
    await tester.binding.handlePopRoute();
    await _advance(tester);
    expect(find.byType(UserHomeScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _advance(tester);
    expect(
        tester.widget<PostDetailScreen>(find.byType(PostDetailScreen)).postId,
        202);
    await tester.binding.handlePopRoute();
    await _advance(tester);
    expect(find.text('选择左侧商品查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final list in [true, false]) {
    testWidgets('集市卡片头像也在右栏打开作者 list=$list', (tester) async {
      final h = await _show(tester);
      await h.theme.setMarketIsListView(list);
      await _advance(tester);
      final avatar = find
          .descendant(
              of: find.byType(MarketPostCard).first,
              matching: find.byType(CachedAvatar))
          .first;
      await tester.tap(avatar);
      await _advance(tester);
      expect(find.byType(UserHomeScreen), findsOneWidget);
      expect(tester.getTopLeft(find.byType(UserHomeScreen)).dx, 484);
      expect(h.root.currentState!.canPop(), isFalse);
      await tester.binding.handlePopRoute();
      await _advance(tester);
      expect(find.text('选择左侧商品查看详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('集市收窄再展开保留回复、焦点及列表滚动，窄屏返回恢复列表', (tester) async {
    await _show(tester,
        adapter: _Adapter()..posts = List.generate(12, (i) => _post(201 + i)));
    await _openProduct(tester);
    final scroll = tester
        .widget<CustomScrollView>(find.descendant(
            of: find.byKey(const ValueKey('market-master-pane')),
            matching: find.byType(CustomScrollView)))
        .controller!;
    scroll.jumpTo(200);
    await tester.pump();
    final detail = tester.state(find.byType(PostDetailScreen));
    final input = find.byKey(const ValueKey('post-reply-input'));
    await tester.enterText(input, '集市草稿');
    await tester.pump();
    for (final size in [const Size(600, 800), const Size(1280, 800)]) {
      await setGoldenViewport(tester, size);
      await _advance(tester);
      expect(tester.state(find.byType(PostDetailScreen)), same(detail));
      expect(tester.widget<TextField>(input).controller!.text, '集市草稿');
      expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      expect(scroll.offset, 200);
    }
    await setGoldenViewport(tester, const Size(600, 800));
    await _advance(tester);
    await tester.tap(find.byType(BackButton));
    await _advance(tester);
    expect(find.byType(PostDetailScreen), findsNothing);
    expect(find.byKey(const ValueKey('market-master-pane')), findsOneWidget);
    expect(scroll.offset, 200);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(390, 844), const Size(943, 800)]) {
    testWidgets('集市扣除侧栏后不足840仍使用整页导航 $size', (tester) async {
      final h = await _show(tester, size: size);
      await _openProduct(tester);
      expect(h.root.currentState!.canPop(), isTrue);
      expect(tester.getTopLeft(find.byType(PostDetailScreen)).dx, 0);
      await tester.binding.handlePopRoute();
      await _advance(tester);
      expect(find.text('集市'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('集市详情刷新失败保留缓存，重新选择后恢复', (tester) async {
    final adapter = _Adapter()..detailStatus = 503;
    await _show(tester, adapter: adapter);
    await _openProduct(tester);
    expect(find.text('集市'), findsOneWidget);
    expect(find.text('内容刷新失败'), findsOneWidget);
    expect(find.text('平板商品 201'), findsNWidgets(2));
    adapter.detailStatus = 200;
    await _openProduct(tester, 202);
    expect(
        tester.widget<PostDetailScreen>(find.byType(PostDetailScreen)).postId,
        202);
    expect(find.text('平板商品 202'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('集市加载、空数据、失败与重试保留分栏', (tester) async {
    final adapter = _Adapter()
      ..feedStatus = 503
      ..feedGate = Completer<void>();
    await _show(tester, adapter: adapter);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('选择左侧商品查看详情'), findsOneWidget);
    adapter.feedGate!.complete();
    await _advance(tester);
    expect(find.text('集市加载失败'), findsOneWidget);
    expect(find.text('选择左侧商品查看详情'), findsOneWidget);
    adapter.feedStatus = 200;
    adapter.posts = [];
    await tester.tap(find.text('重试'));
    await _advance(tester);
    expect(find.text('还没有商品'), findsOneWidget);
    expect(find.text('选择左侧商品查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final change in ['switch', 'relogin', 'logout', 'revoke']) {
    testWidgets('集市清除旧详情及晚到结果 $change', (tester) async {
      final adapter = _Adapter()..detailGate = Completer<void>();
      final h = await _show(tester, adapter: adapter);
      await _openProduct(tester);
      expect(find.byType(PostDetailScreen), findsOneWidget);
      expect(adapter.paths, contains('/posts/201'));
      h.auth.changeSession(
          id: change == 'switch' ? 3 : null,
          login: change == 'logout' ? false : null,
          newRole: change == 'revoke' ? 'guest' : null);
      await _advance(tester);
      expect(find.byType(PostDetailScreen), findsNothing);
      adapter.detailGate!.complete();
      await _advance(tester);
      expect(find.byType(PostDetailScreen), findsNothing);
      expect(find.text('选择左侧商品查看详情'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('集市搜索晚到响应不能回填新会话', (tester) async {
    final adapter = _Adapter()..searchGate = Completer<void>();
    final h = await _show(tester, adapter: adapter);
    await tester.enterText(find.byType(TextField), '旧会话');
    await _advance(tester);
    h.auth.changeSession(id: 3);
    await _advance(tester);
    adapter.searchGate!.complete();
    await _advance(tester);
    expect(find.text('平板商品 299'), findsNothing);
    expect(find.text('平板商品 201'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('游客发布仍先登录，返回后保留集市分栏', (tester) async {
    final h = await _show(tester, adapter: _Adapter()..posts = []);
    h.auth.changeSession(login: false);
    await _advance(tester);
    await tester.tap(find.text('发布商品'));
    await _advance(tester);
    expect(find.text('登录测试页'), findsOneWidget);
    expect(h.root.currentState!.canPop(), isTrue);
    await tester.binding.handlePopRoute();
    await _advance(tester);
    expect(find.text('还没有商品'), findsOneWidget);
    expect(find.text('选择左侧商品查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final embedded in [false, true]) {
    for (final market in [false, true]) {
      testWidgets('个人主页打开内容保留原导航区域 embedded=$embedded market=$market',
          (tester) async {
        final h = await _show(tester, profile: true, embedded: embedded);
        final homeState = tester.state(find.byType(UserHomeScreen));
        if (market) {
          await tester.tap(find.text('商品 1'));
          await _advance(tester);
        }
        await tester.tap(find.text(market ? '平板商品 201' : '主页帖子 301'));
        await _advance(tester);
        expect(h.root.currentState!.canPop(), isFalse);
        expect(tester.getTopLeft(find.byType(PostDetailScreen)).dx, 484);
        expect(
            tester
                .widget<PostDetailScreen>(find.byType(PostDetailScreen))
                .isMarket,
            market);
        expect(find.text(embedded ? '左侧信息流' : '商品作者'), findsWidgets);
        await tester.binding.handlePopRoute();
        await _advance(tester);
        expect(find.byType(PostDetailScreen), findsNothing);
        expect(tester.state(find.byType(UserHomeScreen)), same(homeState));
        expect(find.text(market ? '平板商品 201' : '主页帖子 301'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('集市深色大字下仍能选商品并返回，主栏保留语义', (tester) async {
    final semantics = tester.ensureSemantics();
    final h = await _show(tester, dark: true, scale: 1.3);
    await _openProduct(tester);
    expect(tester.getSemantics(find.text('集市')).label, contains('集市'));
    expect(h.root.currentState!.canPop(), isFalse);
    await tester.tap(find.byType(BackButton));
    await _advance(tester);
    expect(find.text('选择左侧商品查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
