import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/message_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/profile_screen.dart';
import 'package:shenliyuan/theme/app_theme.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/glass_container.dart';
import 'package:shenliyuan/utils/app_navigator.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _AdminAuth extends AuthProvider {
  _AdminAuth(super.dio) : super(loadStoredAuth: false);

  @override
  User get user => User(
        id: 1,
        studentId: 'admin',
        nickname: '管理员',
        role: 'admin',
        createdAt: DateTime(2026),
      );

  @override
  bool get isLoggedIn => true;

  @override
  Future<void> refreshUser() async {}
}

class _PendingAdapter implements HttpClientAdapter {
  final responses = <String, Object>{};
  final requests = <RequestOptions>[];
  String? failedPath;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<List<int>>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    final path = options.uri.path;
    return ResponseBody.fromString(
      jsonEncode(responses[path] ??
          (path == '/user/course-evaluations'
              ? {
                  'items': [],
                  'content_counts': {'posts': 0, 'market': 0, 'evaluations': 0}
                }
              : path == '/user/canteen-reviews'
                  ? {'items': [], 'has_more': false}
              : path.endsWith('count')
                  ? {'count': 0}
                  : <Object>[])),
      path == failedPath ? 500 : 200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

Future<void> _pumpProfile(WidgetTester tester, _PendingAdapter adapter,
    {bool dark = false,
    double textScale = 1,
    ThemeProvider? appearance}) async {
  await setGoldenViewport(tester, GoldenViewports.phone360x800);
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
    ..httpClientAdapter = adapter;
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>(create: (_) => _AdminAuth(dio)),
      ChangeNotifierProvider(
          create: (_) => appearance ?? ThemeProvider(loadOnStart: false)),
      ChangeNotifierProvider(create: (_) => EduProvider(dio)),
      ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
      ChangeNotifierProvider(
          create: (_) => MessageProvider(dio, enableRealtime: false)),
    ],
    child: MaterialApp(
      theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const ProfileScreen(),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _adminEntry() =>
    find.ancestor(of: find.text('管理处'), matching: find.byType(InkWell));

void main() {
  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('个人页分组标题保持透明且不移动 dark=$dark scale=$scale', (tester) async {
        AppPreferencesStore.setMockInitialValues({});
        final appearance = ThemeProvider(loadOnStart: false);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        await appearance.setComponentOpacity(.75);
        await _pumpProfile(tester, _PendingAdapter(),
            dark: dark, textScale: scale, appearance: appearance);
        final nickname = find.text('管理员').first;
        final headerRect = tester.getRect(nickname);
        final stats = find.text('关注的人');
        final statsRect = tester.getRect(stats);
        for (final glass in [true, false]) {
          await appearance.setFrostedGlass(glass);
          await tester.pumpAndSettle();
          expect(
              find.ancestor(
                  of: nickname, matching: find.byType(AppContentSurface)),
              findsNothing,
              reason: '头像和昵称区域融入壁纸，不增加整块底面');
          expect(
              find.ancestor(
                  of: nickname, matching: find.byType(AppCardSurface)),
              findsNothing);
          expect(tester.getRect(nickname), headerRect);
          expect(tester.getRect(stats), statsRect);
          expect(
              find.ancestor(of: stats, matching: find.byType(GlassContainer)),
              findsOneWidget);
          expect(
              find.ancestor(
                  of: find.text('工单管理'), matching: find.byType(GlassContainer)),
              findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        for (final label in ['管理员', '社区参与', '教务', '我的内容', '服务与支持', '设置']) {
          final title = find.byKey(ValueKey('profile-section-$label'));
          await tester.scrollUntilVisible(find.text(label).last, 220,
              scrollable: find.byType(Scrollable).first);
          await tester.pumpAndSettle();
          expect(title, findsOneWidget);
          expect(tester.widget(title), isA<Text>());
          final rect = tester.getRect(title);
          for (final glass in [true, false]) {
            await appearance.setFrostedGlass(glass);
            await tester.pumpAndSettle();
            expect(tester.getRect(title), rect);
            expect(tester.widget<Text>(title).style!.color,
                Theme.of(tester.element(title)).colorScheme.onSurfaceVariant);
            expect(
                find.ancestor(
                    of: title, matching: find.byType(AppContentSurface)),
                findsNothing);
            expect(
                find.ancestor(of: title, matching: find.byType(AppCardSurface)),
                findsNothing);
            expect(tester.takeException(), isNull);
          }
        }
      });
    }
  }

  testWidgets('Pad 个人页保持阅读宽度与管理员角标', (tester) async {
    await _pumpProfile(tester, _PendingAdapter(), dark: true, textScale: 1.3);
    for (final size in [
      GoldenViewports.tabletPortrait834x1194,
      GoldenViewports.tabletLandscape1280x800
    ]) {
      await setGoldenViewport(tester, size);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(CustomScrollView)).width,
          lessThanOrEqualTo(840));
      expect(find.text('管理处'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
  setUpAll(loadTestFonts);
  setUp(() => currentHomeTabIndex.value = 4);

  for (final config in [(false, 1.0), (true, 1.0), (false, 1.3)]) {
    testWidgets('仅课程评价待审时入口显示角标 dark=${config.$1} scale=${config.$2}',
        (tester) async {
      final adapter = _PendingAdapter();
      adapter.responses['/admin/course-evaluations/pending'] = {
        'items': [
          {'id': 1}
        ]
      };
      await _pumpProfile(tester, adapter,
          dark: config.$1, textScale: config.$2);
      expect(find.descendant(of: _adminEntry(), matching: find.text('1')),
          findsOneWidget);
      expect(find.text('处理举报与社区治理 · 1 条待办'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('课表返回个人页更新待办，处理后返回管理处入口清除角标', (tester) async {
    final adapter = _PendingAdapter();
    await _pumpProfile(tester, adapter);
    expect(find.text('处理举报与社区治理'), findsOneWidget);

    currentHomeTabIndex.value = 2;
    adapter.responses['/admin/course-evaluations/pending'] = {
      'items': [
        {'id': 1}
      ]
    };
    currentHomeTabIndex.value = 4;
    await tester.pumpAndSettle();
    expect(find.descendant(of: _adminEntry(), matching: find.text('1')),
        findsOneWidget);

    await tester.ensureVisible(find.text('管理处'));
    await tester.tap(find.text('管理处'));
    await tester.pumpAndSettle();
    adapter.responses['/admin/course-evaluations/pending'] = {'items': []};
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('处理举报与社区治理'), findsOneWidget);
    expect(find.descendant(of: _adminEntry(), matching: find.text('1')),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('汇总各类待办并保留管理员投票资格过滤', (tester) async {
    final adapter = _PendingAdapter();
    adapter.responses.addAll({
      '/reports': [
        {'id': 1}
      ],
      '/admin/featured-applications': [
        {'id': 1}
      ],
      '/teachers/pending': [
        {'id': 1}
      ],
      '/majors/pending': [
        {'id': 1}
      ],
      '/canteens/pending': {
        'items': [
          {'id': 1}
        ]
      },
      '/admin/course-evaluations/pending': {
        'items': [
          {'id': 1}
        ]
      },
      '/admin/exam-papers/pending-count': {'count': 3},
      '/admin/water/section-icon-reviews': {
        'reviews': [
          {'id': 1}
        ]
      },
      '/admin/invitations/pending': [
        {'my_vote': true},
        {'my_vote': false}
      ],
      '/admin/removals/pending': [
        {'can_vote': true},
        {'can_vote': false}
      ],
    });
    await _pumpProfile(tester, adapter);
    expect(find.descendant(of: _adminEntry(), matching: find.text('12')),
        findsOneWidget);
    for (final path in ['/reports', '/admin/water/section-icon-reviews']) {
      expect(
          adapter.requests
              .singleWhere((r) => r.path == path)
              .queryParameters['status'],
          'pending');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('单类接口失败仍显示其他已确认待办，大数字角标限制宽度', (tester) async {
    final adapter = _PendingAdapter()..failedPath = '/reports';
    adapter.responses['/admin/exam-papers/pending-count'] = {'count': 120};
    await _pumpProfile(tester, adapter, dark: true, textScale: 1.3);
    expect(find.descendant(of: _adminEntry(), matching: find.text('99+')),
        findsOneWidget);
    expect(find.text('处理举报与社区治理 · 120 条待办'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
