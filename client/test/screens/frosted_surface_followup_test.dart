import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/post.dart';
import 'package:shenliyuan/config/water_post_taxonomy.dart';
import 'package:shenliyuan/models/water_section.dart';
import 'package:shenliyuan/providers/water_section_provider.dart';
import 'package:shenliyuan/providers/water_moderator_provider.dart';
import 'package:shenliyuan/screens/water_category_feed_screen.dart';
import 'package:shenliyuan/widgets/water_section/section_filter_header.dart';
import 'package:shenliyuan/app_bootstrap.dart' show getSharedDio;
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/poll_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/erke_score_screen.dart';
import 'package:shenliyuan/screens/market_screen.dart';
import 'package:shenliyuan/screens/poll/poll_detail_screen.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/screens/admin_members_screen.dart';
import 'package:shenliyuan/screens/admin/admin_feedback_screen.dart';
import 'package:shenliyuan/screens/notifications_screen.dart';
import 'package:shenliyuan/screens/court_hub_screen.dart';
import 'package:shenliyuan/services/poll_service.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';
import 'package:shenliyuan/widgets/home_service_drawer.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _FixtureAuth extends AuthProvider {
  _FixtureAuth(super.dio) : super(loadStoredAuth: false);
  @override
  User get user => User(
      id: 77,
      studentId: 'fixture-student',
      nickname: '测试同学',
      createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => true;
}

Map<String, dynamic> _post(bool poll) => {
      'id': 1,
      'author_id': 2,
      'board_id': poll ? 1 : 2,
      'title': poll ? '测试投票' : '测试招领',
      'content': '测试内容',
      'post_type': poll ? 'poll' : 'found',
      'content_kind': poll ? 'poll' : 'text',
      'status': 'normal',
      'created_at': '2026-10-25T08:00:00Z',
      if (poll)
        'poll_meta': {
          'id': 1,
          'post_id': 1,
          'category': 'other',
          'selection_mode': 'single',
          'max_choices': 1,
          'results_visibility': 'always',
          'status': 'active',
          'effective_status': 'active',
          'remaining_seconds': 3600,
          'participant_count': 0,
          'has_voted': false,
          'results_visible': true,
          'can_vote': false,
          'can_change': false,
          'is_owner': false,
          'options': [
            {'id': 10, 'text': '选项一', 'vote_count': 0, 'ratio': 0}
          ],
        },
    };

Dio _api(String page) {
  final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    if (options.path == '/admin/members') {
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: [
        {
          'id': 2,
          'nickname': '测试管理员',
          'student_id': 'fixture-admin',
          'role': 'admin'
        },
      ]));
      return;
    }
    if (options.path == '/notifications') {
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: [
        {
          'id': 1,
          'type': 'system',
          'content': '测试通知',
          'is_read': true,
          'created_at': '2026-10-25T08:00:00Z'
        },
      ]));
      return;
    }
    if (options.path.startsWith('/admin/feedback')) {
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'tickets': [
          {
            'id': 1,
            'ticket_no': 'fixture-ticket',
            'user_id': 77,
            'title': '测试工单',
            'status': 'pending'
          }
        ],
        'has_more': false,
      }));
      return;
    }
    handler.resolve(Response(
      requestOptions: options,
      statusCode: 200,
      data: options.path.contains('/replies')
          ? {'replies': [], 'total': 0}
          : options.path == '/polls/1'
              ? _post(true)
              : options.path == '/posts/1'
                  ? _post(false)
                  : options.path == '/posts'
                      ? {
                          'posts': [_post(false)],
                          'total': 1
                        }
                      : {'items': [], 'count': 0, 'has_pending': false},
    ));
  }));
  return dio;
}

Widget _drawer(VoidCallback onToolbox) => HomeServiceDrawer(
      checkedIn: false,
      streakDays: 0,
      checkInLoading: false,
      showCheckInDot: false,
      announcements: const [],
      unreadAnnouncements: const [],
      onCheckIn: () {},
      onOpenToolbox: onToolbox,
      onOpenAnnouncements: () {},
      onOpenCompetitions: () {},
      onOpenGrades: () {},
      onOpenExamSchedule: () {},
      onOpenFeedback: () {},
      onOpenWaterSectionDirectory: () {},
    );

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['BACKGROUND_QA_DIR'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    try {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(directory).create(recursive: true);
      await File('$directory/$name.png').writeAsBytes(png.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final profile in ['light', 'dark', 'large-text']) {
    for (final page in [
      'market',
      'drawer',
      'erke',
      'poll',
      'market-detail',
      'admin-members',
      'admin-feedback',
      'court',
      'notifications'
      , 'section'
    ]) {
      testWidgets('$page $profile 自定义背景与材质、关闭回退、基本交互', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final theme = ThemeProvider(loadOnStart: false);
        addTearDown(theme.dispose);
        await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: true);
        await theme.setComponentOpacity(.7);
        await theme.setFrostedGlass(true);
        final dio = _api(page);
        if (page == 'court') {
          final interceptor =
              InterceptorsWrapper(onRequest: (options, handler) {
            handler.resolve(
                Response(requestOptions: options, statusCode: 200, data: []));
          });
          getSharedDio().interceptors.insert(0, interceptor);
          addTearDown(() => getSharedDio().interceptors.remove(interceptor));
        }
        var toolboxTaps = 0;
        final capture = GlobalKey();
        final screen = switch (page) {
          'market' => const GlobalBackgroundWrapper(child: MarketScreen()),
          'drawer' => Scaffold(body: _drawer(() => toolboxTaps++)),
          'erke' => const ErkeScoreScreen(),
          'poll' => const PollDetailScreen(pollId: 1),
          'admin-members' => const AdminMembersScreen(),
          'admin-feedback' => const AdminFeedbackScreen(),
          'court' => const CourtHubScreen(),
          'notifications' => const NotificationsScreen(),
          'section' => WaterCategoryFeedScreen(
            category: kWaterPostCategories.first,
            section: WaterSection.fromLegacyCategory(kWaterPostCategories.first)),
          _ => PostDetailScreen(
              postId: 1,
              isMarket: true,
              initialPost: Post.fromJson(_post(false))),
        };
        await tester.pumpWidget(MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: theme),
              ChangeNotifierProvider(create: (_) => WaterSectionProvider(dio)),
              ChangeNotifierProvider(create: (_) => WaterModeratorProvider(dio)),
              ChangeNotifierProvider<AuthProvider>(
                  create: (_) => _FixtureAuth(dio)),
              ChangeNotifierProvider(
                  create: (_) => PostProvider(dio, enableCache: false)),
              ChangeNotifierProvider(
                  create: (_) => PollProvider(PollService(dio))),
            ],
            child: RepaintBoundary(
                key: capture,
                child: GoldenTestApp(
                  themeMode:
                      profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
                  textScaler: profile == 'large-text'
                      ? GoldenTextProfile.large.scaler
                      : TextScaler.noScaling,
                  home: screen,
                ))));
        await tester.pumpAndSettle();
        final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
        await tester
            .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
        await tester.pumpAndSettle();
        expect(find.byType(CustomBackgroundLayer), findsWidgets);
        expect(find.byType(BackdropFilter), findsWidgets);
        expect(tester.takeException(), isNull);
        await _capture(tester, capture, '$page-$profile-glass');

        if (page == 'market') {
          final search = find.byType(TextField);
          final surface =
              find.ancestor(of: search, matching: find.byType(AppCardSurface));
          expect(
              find.descendant(
                  of: surface, matching: find.byType(BackdropFilter)),
              findsOneWidget);
          expect((tester.getCenter(find.descendant(of: search, matching: find.byType(EditableText))).dy -
              tester.getCenter(surface).dy).abs(), lessThanOrEqualTo(1));
          for (final label in ['全部', '出售', '最新发布', '筛选']) {
            final control = find.ancestor(of: find.text(label), matching:
                find.byWidgetPredicate((w) => w is AppCardSurface || w is AppCardMaterial)).first;
            expect(find.descendant(of: control, matching: find.byType(BackdropFilter)), findsOneWidget);
          }
          await tester.enterText(search, '自行车');
          await tester.pumpAndSettle();
          expect(tester.widget<TextField>(search).controller!.text, '自行车');
        } else if (page == 'drawer') {
          // 五个分组各一层材质，内部版块项不能重复套玻璃。
          expect(find.byType(BackdropFilter), findsNWidgets(5));
          await tester.tap(find.text('工具箱'));
          expect(toolboxTaps, 1);
        } else if (page == 'erke') {
          expect(find.byType(TextField), findsNWidgets(2));
          await tester.tap(find.text('更新二课数据'));
          await tester.pumpAndSettle();
          expect(find.text('请填写完整信息'), findsOneWidget);
        } else if (page == 'poll') {
          final divider = find.byType(AppCardDivider);
          expect(divider, findsOneWidget);
          expect(find.descendant(of: divider, matching: find.byType(DecoratedBox)), findsNothing);
          expect(find.text('选项一'), findsOneWidget);
          expect(
              tester
                  .widget<TextField>(find.byType(TextField))
                  .focusNode!
                  .hasFocus,
              isFalse);
        } else if (page == 'market-detail') {
          expect(find.text('测试招领'), findsOneWidget);
        } else if (page == 'admin-members') {
          expect(find.text('测试管理员'), findsOneWidget);
        } else if (page == 'admin-feedback') {
          expect(find.text('测试工单'), findsOneWidget);
        } else if (page == 'notifications') {
          expect(find.text('测试通知'), findsOneWidget);
        } else if (page == 'court') {
          expect(find.text('暂时没有待你陪审的案件'), findsOneWidget);
        } else if (page == 'section') {
          expect(tester.widget<SliverAppBar>(find.byType(SliverAppBar)).backgroundColor, Colors.transparent);
          expect(find.descendant(of: find.byType(SectionFilterHeader), matching: find.byType(BackdropFilter)), findsOneWidget);
        }

        await theme.setCleanBackgroundMode();
        await tester.pumpAndSettle();
        await _capture(tester, capture, '$page-$profile-clean');
        expect(tester.takeException(), isNull);
        await theme.setFrostedGlass(false);
        await tester.pumpAndSettle();
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
