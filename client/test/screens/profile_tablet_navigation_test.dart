import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/course_evaluation_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/social_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/screens/my_content_screen.dart';
import 'package:shenliyuan/screens/profile_screen.dart';
import 'package:shenliyuan/screens/settings/appearance_settings_screen.dart';
import 'package:shenliyuan/screens/settings_screen.dart';
import 'package:shenliyuan/screens/social_list_screen.dart';
import 'package:shenliyuan/screens/user_home_screen.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/utils/app_navigator.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/widgets/community_post_card.dart';
import 'package:shenliyuan/widgets/market_post_card.dart';
import 'package:shenliyuan/widgets/profile_detail_layout.dart';

import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/mock_public_image_http.dart';

class _Auth extends AuthProvider {
  _Auth(super.dio) : super(loadStoredAuth: false);
  int account = 70;
  int epoch = 0;
  bool loggedIn = true;
  String role = 'user';
  @override
  User? get user => loggedIn
      ? User(
          id: account,
          studentId: 'test',
          nickname: '分栏测试',
          background: 'https://example.test/uploads/personal-cover.jpg',
          role: role,
          createdAt: DateTime(2026))
      : null;
  @override
  int get accountSessionEpoch => epoch;
  @override
  bool get isLoggedIn => loggedIn;
  @override
  Future<void> refreshUser() async {}
  void changeSession({int? id, bool? login, String? newRole}) {
    account = id ?? account;
    loggedIn = login ?? loggedIn;
    role = newRole ?? role;
    epoch++;
    notifyListeners();
  }

  void revokeRole() {
    role = 'user';
    notifyListeners();
  }
}

class _Adapter implements HttpClientAdapter {
  bool userHomeContent = false;
  int socialStatus = 200;
  Completer<ResponseBody>? socialPending;
  Completer<ResponseBody>? unreadPending;
  final requests = <RequestOptions>[];
  @override
  void close({bool force = false}) {}
  ResponseBody response(Object data, [int status = 200]) =>
      ResponseBody.fromString(jsonEncode(data), status, headers: {
        Headers.contentTypeHeader: ['application/json']
      });
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? stream,
      Future<void>? cancel) async {
    requests.add(options);
    final path = options.path;
    if (path.endsWith('/following') || path.endsWith('/followers')) {
      if (socialPending != null) return socialPending!.future;
      return response({'items': [], 'total': 0}, socialStatus);
    }
    if (path == '/user/notifications/unread_count' && unreadPending != null) {
      return unreadPending!.future;
    }
    if (path == '/user/course-evaluations') {
      return response({
        'items': [],
        'total': 0,
        'has_more': false,
        'content_counts': {'posts': 0, 'market': 0, 'evaluations': 0}
      });
    }
    if (userHomeContent &&
        (path == '/user/70/posts' || path == '/user/70/market-posts')) {
      final market = path.endsWith('/market-posts');
      final post = {
        'id': market ? 202 : 201,
        'title': market ? '主页测试商品' : '主页测试帖子',
        'content': '对齐测试内容',
        'board_id': market ? 2 : 1,
        'author_id': 70,
        'created_at': '2026-10-08T00:00:00Z',
      };
      return response(market
          ? {
              'items': [post],
              'total': 1,
              'sold': 0
            }
          : [post]);
    }
    if (path.endsWith('/posts')) return response([]);
    if (path.endsWith('/market-posts') || path == '/user/canteen-reviews') {
      return response({'items': [], 'total': 0, 'has_more': false});
    }
    if (path == '/user/invitations') return response([]);
    return response({'count': 0, 'unread_count': 0});
  }
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
  final rootKey = GlobalKey<NavigatorState>();
  final theme = ThemeProvider(loadOnStart: false);
  final active = ValueNotifier(true);
  Widget app({bool dark = false, double scale = 1, double rail = 0}) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider.value(value: theme),
          ChangeNotifierProvider(create: (_) => EduProvider(dio)),
          ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
          ChangeNotifierProvider(
              create: (_) => MessageProvider(dio, enableRealtime: false)),
          ChangeNotifierProvider(create: (_) => SocialProvider(dio)),
          ChangeNotifierProvider(create: (_) => WaterSectionProvider(null)),
          ChangeNotifierProvider(create: (_) => CourseEvaluationProvider(dio)),
        ],
        child: MaterialApp(
          navigatorKey: rootKey,
          navigatorObservers: [appRouteObserver],
          theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
          routes: {'/login': (_) => const Scaffold(body: Text('登录测试页'))},
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: GlobalBackgroundWrapper(
              child: Row(children: [
            SizedBox(width: rail),
            Expanded(
                child: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, value, __) => ProfileScreen(isActive: value),
            )),
          ])),
        ),
      );
  void dispose() {
    auth.dispose();
    theme.dispose();
    active.dispose();
  }
}

Future<_Harness> _show(WidgetTester tester,
    {Size size = const Size(1280, 800),
    _Adapter? adapter,
    bool dark = false,
    double scale = 1,
    double rail = 112,
    bool guest = false,
    bool admin = false}) async {
  await setGoldenViewport(tester, size);
  final h = _Harness(adapter ?? _Adapter());
  h.auth.loggedIn = !guest;
  if (admin) h.auth.role = 'admin';
  addTearDown(h.dispose);
  await tester.pumpWidget(h.app(dark: dark, scale: scale, rail: rail));
  await _advance(tester);
  return h;
}

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Finder _master() => find.byKey(const ValueKey('profile-master-pane'));
Finder _detail() => find.byKey(const ValueKey('profile-detail-pane'));
Finder _entry(String text) =>
    find.descendant(of: _master(), matching: find.text(text)).first;
Future<void> _tapEntry(WidgetTester tester, String text) async {
  final target = text == '设置'
      ? find.byKey(const ValueKey('profile-entry-设置'))
      : _entry(text);
  if (text == '设置') {
    await tester.scrollUntilVisible(target, 240,
        scrollable: find
            .descendant(of: _master(), matching: find.byType(Scrollable))
            .first);
  } else {
    await tester.ensureVisible(target);
  }
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    currentHomeTabIndex.value = 4;
  });

  testWidgets('平板我的内容、关注和粉丝在右侧切换，不累积入口栈', (tester) async {
    final h = await _show(tester);
    await tester.pumpAndSettle();
    final masterState = tester.state(find.byType(ProfileScreen));
    expect(tester.getSize(_master()).width, 380);
    expect(find.text('选择左侧功能查看详情'), findsOneWidget);
    await _tapEntry(tester, '我的内容');
    expect(find.byType(MyContentScreen), findsOneWidget);
    expect(tester.getTopLeft(find.byType(MyContentScreen)).dx, 492);
    expect(h.rootKey.currentState!.canPop(), isFalse);
    await _tapEntry(tester, '关注的人');
    expect(find.byType(MyContentScreen), findsNothing);
    expect(find.text('暂无关注'), findsOneWidget);
    await _tapEntry(tester, '关注我的');
    expect(
        tester
            .widget<SocialListScreen>(find.byType(SocialListScreen))
            .initialIndex,
        1);
    expect(find.text('暂无粉丝'), findsOneWidget);
    await _tapEntry(tester, '关注的人');
    expect(find.text('暂无关注'), findsOneWidget);
    expect(tester.state(find.byType(ProfileScreen)), same(masterState));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SocialListScreen), findsNothing);
    expect(find.text('选择左侧功能查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右侧路由不能遮掉左侧我的主页的读屏和触控入口', (tester) async {
    final handle = tester.ensureSemantics();
    await _show(tester);
    await _tapEntry(tester, '关注的人');
    final labels = <String>[];
    void collect(SemanticsNode node) {
      labels.add(node.label);
      node.visitChildren((child) {
        collect(child);
        return true;
      });
    }

    collect(tester
        .binding.renderViews.single.owner!.semanticsOwner!.rootSemanticsNode!);
    expect(labels.any((label) => label.contains('关注的人')), isTrue);
    expect(labels.any((label) => label.contains('关注我的')), isTrue);
    expect(labels.any((label) => label.contains('关注与粉丝')), isTrue);
    expect(_entry('关注我的').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('设置继续进入界面设置仍留在右侧，返回逐层退出且左侧不跳动', (tester) async {
    await _show(tester);
    await _tapEntry(tester, '设置');
    final position = tester
        .state<ScrollableState>(find
            .descendant(of: _master(), matching: find.byType(Scrollable))
            .first)
        .position;
    final offset = position.pixels;
    await tester.tap(find.text('界面设置'));
    await tester.pumpAndSettle();
    expect(find.byType(AppearanceSettingsScreen), findsOneWidget);
    expect(tester.getTopLeft(find.byType(AppearanceSettingsScreen)).dx, 492);
    expect(position.pixels, offset);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(position.pixels, offset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('我的二级页和继续打开的设置共用整屏壁纸，不在右栏重复铺图', (tester) async {
    final h = await _show(tester);
    await h.theme.setBackgroundImage('morenbeijing.jpeg');
    await h.theme.setBackgroundBlur(10);
    await tester.pumpAndSettle();
    await _tapEntry(tester, '设置');
    final wallpaper = find.byWidgetPredicate((widget) =>
        widget is Image && widget.image is AspectPreservingResizeImage);
    expect(wallpaper, findsOneWidget);
    expect(find.descendant(of: _detail(), matching: wallpaper), findsNothing);
    await tester.tap(find.text('界面设置'));
    await tester.pumpAndSettle();
    expect(wallpaper, findsOneWidget);
    expect(find.descendant(of: _detail(), matching: wallpaper), findsNothing);
    expect(find.text('字体大小'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1168.0, 1440.0]) {
    testWidgets('分栏保留封面且帖子商品与标签栏对齐 width=$width', (tester) async {
      await tester.runAsync(installMockPublicImageHttp);
      addTearDown(uninstallMockPublicImageHttp);
      final h = await _show(tester,
          size: Size(width, 900), adapter: _Adapter()..userHomeContent = true);
      await h.theme.setBackgroundImage('morenbeijing.jpeg');
      await tester.pumpAndSettle();
      tester
          .state<ProfileDetailLayoutState>(find.byType(ProfileDetailLayout))
          .open(MaterialPageRoute(builder: (_) => const UserHomeScreen()));
      await tester.pumpAndSettle();
      final home = find.byType(UserHomeScreen);
      expect(find.text('编辑资料'), findsOneWidget);
      expect(find.text('主页测试帖子'), findsOneWidget);
      final tabs = find.descendant(of: home, matching: find.byType(TabBar));
      final postCard =
          find.descendant(of: home, matching: find.byType(CommunityPostCard));
      expect(tester.getRect(postCard).left, tester.getRect(tabs).left);
      expect(tester.getRect(postCard).right, tester.getRect(tabs).right);
      await tester.tap(find.text('商品 1'));
      await tester.pumpAndSettle();
      final marketCard =
          find.descendant(of: home, matching: find.byType(MarketPostCard));
      expect(find.text('主页测试商品'), findsOneWidget);
      expect(tester.getRect(marketCard).left, tester.getRect(tabs).left);
      expect(tester.getRect(marketCard).right, tester.getRect(tabs).right);
      final cover = find.descendant(
          of: home,
          matching: find.byWidgetPredicate((widget) =>
              widget is CachedNetworkImage &&
              widget.imageUrl ==
                  'https://example.test/uploads/personal-cover.jpg'));
      expect(cover, findsOneWidget);
      bool coverLoaded() => tester
          .widgetList<RawImage>(
              find.descendant(of: cover, matching: find.byType(RawImage)))
          .any((image) => image.image != null);
      await driveMockPublicImageLoads(tester, until: coverLoaded);
      expect(coverLoaded(), isTrue, reason: '共享的是页面壁纸，用户设置的个人封面仍正常加载');
      expect(
          find.byWidgetPredicate((widget) =>
              widget is Image && widget.image is AspectPreservingResizeImage),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await flushMockPublicImageTimers(tester);
    });
  }

  for (final size in [const Size(390, 844), const Size(834, 1194)]) {
    testWidgets('可用宽度不足时沿用整页导航 $size', (tester) async {
      final h =
          await _show(tester, size: size, rail: size.width < 600 ? 0 : 112);
      await tester.pumpAndSettle();
      await _tapEntry(tester, '关注的人');
      expect(h.rootKey.currentState!.canPop(), isTrue);
      expect(_master(), findsNothing);
      expect(find.byType(SocialListScreen), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(_master(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('分栏收窄再展开保留详情实例、选中标签和左侧滚动', (tester) async {
    await _show(tester);
    await _tapEntry(tester, '关注的人');
    await tester.tap(find.text('粉丝'));
    await tester.pumpAndSettle();
    final detailState = tester.state(find.byType(SocialListScreen));
    for (final size in [const Size(800, 1000), const Size(1280, 800)]) {
      await setGoldenViewport(tester, size);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SocialListScreen)), same(detailState));
      expect(find.text('暂无粉丝'), findsOneWidget);
      expect(_master(), size.width < 952 ? findsNothing : findsOneWidget);
    }
    await setGoldenViewport(tester, const Size(600, 800));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SocialListScreen), findsNothing);
    expect(_master(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('右侧加载、失败和重试不覆盖我的主页', (tester) async {
    final adapter = _Adapter()..socialPending = Completer<ResponseBody>();
    await _show(tester, adapter: adapter);
    await tester.tap(_entry('关注的人'));
    await _advance(tester);
    expect(
        find.descendant(
            of: _detail(), matching: find.byType(CircularProgressIndicator)),
        findsWidgets);
    expect(_entry('分栏测试'), findsOneWidget);
    adapter.socialPending!.complete(adapter.response({'error': '本地失败'}, 503));
    adapter.socialPending = null;
    await tester.pumpAndSettle();
    expect(find.text('获取关注列表失败，请稍后重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂无关注'), findsOneWidget);
    expect(_entry('分栏测试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final transition in [
    'switch',
    'logout',
    'same-account-login',
    'revoke'
  ]) {
    testWidgets('会话变化清空右侧详情 $transition', (tester) async {
      final h = await _show(tester, admin: transition == 'revoke');
      await _tapEntry(tester, '关注的人');
      if (transition == 'switch') h.auth.changeSession(id: 71);
      if (transition == 'logout') h.auth.changeSession(login: false);
      if (transition == 'same-account-login') h.auth.changeSession();
      if (transition == 'revoke') h.auth.revokeRole();
      await tester.pumpAndSettle();
      expect(find.byType(SocialListScreen, skipOffstage: false), findsNothing);
      expect(find.text('选择左侧功能查看详情'), findsOneWidget);
      expect(h.rootKey.currentState!.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('旧会话延迟响应不能重新显示已清空的右侧内容和未读数', (tester) async {
    final adapter = _Adapter()
      ..socialPending = Completer<ResponseBody>()
      ..unreadPending = Completer<ResponseBody>();
    final h = await _show(tester, adapter: adapter);
    await tester.tap(_entry('关注的人'));
    await _advance(tester);
    final socialPending = adapter.socialPending!;
    final unreadPending = adapter.unreadPending!;
    adapter.socialPending = null;
    adapter.unreadPending = null;
    h.auth.changeSession(id: 72);
    await tester.pumpAndSettle();
    socialPending.complete(adapter.response({
      'items': [
        {'id': 999, 'nickname': '旧账号内容', 'student_id': 'old'}
      ],
      'total': 1
    }));
    unreadPending.complete(adapter.response({'count': 88}));
    await tester.pumpAndSettle();
    expect(find.text('旧账号内容'), findsNothing);
    expect(find.text('88条新通知'), findsNothing);
    expect(find.text('选择左侧功能查看详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final config in [(false, 1.0), (true, 1.3)]) {
    testWidgets('平板设置分栏适应主题和大字号 $config', (tester) async {
      final h = await _show(tester, dark: config.$1, scale: config.$2);
      await h.theme.setBackgroundImage('morenbeijing.jpeg');
      await _tapEntry(tester, '设置');
      for (final glass in [false, true]) {
        await h.theme.setFrostedGlass(glass);
        await tester.pumpAndSettle();
        expect(find.text('界面设置'), findsOneWidget);
        expect(tester.getRect(_master()).right, tester.getRect(_detail()).left);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('其他根标签启用时，我的详情不会截获系统返回', (tester) async {
    final h = await _show(tester);
    await _tapEntry(tester, '关注的人');
    currentHomeTabIndex.value = 0;
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<NavigatorPopHandler<Object?>>(
                find.byType(NavigatorPopHandler<Object?>))
            .enabled,
        isFalse);
    expect(await h.rootKey.currentState!.maybePop(), isFalse);
    expect(find.byType(SocialListScreen), findsOneWidget);
    currentHomeTabIndex.value = 4;
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SocialListScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未登录打开设置和登录入口可返回，不丢失主栏', (tester) async {
    final h = await _show(tester, guest: true);
    await _tapEntry(tester, '设置');
    await tester.tap(find.text('登录沈理校园'));
    await tester.pumpAndSettle();
    // 设置内使用原来的 MaterialPageRoute 打开登录页，仍属于右侧 Navigator。
    expect(tester.getSize(_master()).width, 380);
    expect(h.rootKey.currentState!.canPop(), isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
