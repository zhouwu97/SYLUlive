import 'package:shenliyuan/widgets/bottom_nav.dart';
import 'package:shenliyuan/screens/post_detail_screen.dart';
import 'package:shenliyuan/screens/user_home_screen.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';
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
import 'package:shenliyuan/screens/shuitie_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _FeedAuthProvider extends ChangeNotifier implements AuthProvider {
  _FeedAuthProvider({required this.client});

  final Dio client;

  @override
  User? get user => User(
      id: 1, studentId: 'test', nickname: '测试用户', createdAt: DateTime(2026));

  @override
  bool get isLoggedIn => true;

  @override
  int get sessionGeneration => 0;
  @override
  int get accountSessionEpoch => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Map<String, dynamic> _post(int id, String title, DateTime createdAt) => {
      'id': id,
      'title': title,
      'content': '内容 $id',
      'board_id': 1,
      'author_id': 1,
      'created_at': createdAt.toUtc().toIso8601String(),
    };

/// `/posts` 按 `sort` 返回不同数据：`time` 返回调用方传入的顺序，
/// 其余 sort 返回空列表。这样能证明客户端没有对 time 结果做二次加工。
Dio _feedDio({required List<Map<String, dynamic>> timePosts}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/posts/100') {
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: _post(100, '平板测试帖 100', DateTime(2026, 10, 8))));
          return;
        }
        if (options.path == '/posts/100/replies') {
          handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'replies': [], 'total': 0, 'next_cursor': ''}));
          return;
        }
        if (options.path == '/posts') {
          final sort = options.queryParameters['sort'];
          final posts = sort == 'time' ? timePosts : <dynamic>[];
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'posts': posts,
                'pinned_posts': <dynamic>[],
                'total': posts.length,
              },
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
  return dio;
}

Future<_FeedTestPage> _pumpFeed(
  WidgetTester tester, {
  required List<Map<String, dynamic>> timePosts,
}) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  await setGoldenViewport(tester, auditFeedSize);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dio = _feedDio(timePosts: timePosts);
  final auth = _FeedAuthProvider(client: dio);
  final postProvider = PostProvider(dio, enableCache: false);
  final messageProvider = MessageProvider(dio);
  final themeProvider = ThemeProvider(loadOnStart: false);
  if (auditFeedRail) {
    await themeProvider.setBottomNavStyle(BottomNavStyle.normal);
  }
  final sectionProvider = WaterSectionProvider(null);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<PostProvider>.value(value: postProvider),
        ChangeNotifierProvider<MessageProvider>.value(value: messageProvider),
        ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
        ChangeNotifierProvider<WaterSectionProvider>.value(
          value: sectionProvider,
        ),
      ],
      child: GoldenTestApp(
          home: RepaintBoundary(
              key: feedBoundary,
              child: Scaffold(
                  extendBody: true,
                  body: Row(children: [
                    if (auditFeedRail) const SizedBox(width: 104),
                    const Expanded(child: ShuitieScreen())
                  ]),
                  bottomNavigationBar: auditFeedRail
                      ? null
                      : BottomNavWrapper(
                          currentIndex: 0,
                          visualIndexListenable: feedIndex,
                          onTap: (_) {},
                          authProvider: auth)))),
    ),
  );
  await tester.pumpAndSettle();

  return _FeedTestPage(
    auth: auth,
    postProvider: postProvider,
    messageProvider: messageProvider,
    themeProvider: themeProvider,
    sectionProvider: sectionProvider,
  );
}

Future<void> _dispose(WidgetTester tester, _FeedTestPage page) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  page.auth.dispose();
  page.postProvider.dispose();
  page.messageProvider.dispose();
  page.themeProvider.dispose();
  page.sectionProvider.dispose();
}

final feedBoundary = GlobalKey();
final feedIndex = ValueNotifier<double>(0);
bool auditFeedRail = false;
Size auditFeedSize = const Size(840, 1024);

void main() {
  testWidgets('分栏用户主页请求失败并收窄后仍可返回水贴列表', (tester) async {
    auditFeedRail = false;
    auditFeedSize = GoldenViewports.tabletLandscape1280x800;
    final page = await _pumpFeed(tester,
        timePosts: [_post(100, '平板测试帖 100', DateTime(2026, 10, 8))]);
    await tester.tap(find.text('最新').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('平板测试帖 100').first);
    await tester.pumpAndSettle();
    tester
        .widget<PostDetailScreen>(find.byType(PostDetailScreen))
        .onAuthorTap!(2);
    await tester.pumpAndSettle();
    await setGoldenViewport(tester, GoldenViewports.tabletSplit600x800);
    await tester.pumpAndSettle();
    expect(find.byType(UserHomeScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(UserHomeScreen), findsNothing);
    expect(find.text('平板测试帖 100'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _dispose(tester, page);
  });
  setUpAll(loadTestFonts);
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  tearDown(() {
    VisibilityDetectorController.instance.updateInterval =
        const Duration(milliseconds: 500);
  });
  for (final rail in [false, true]) {
    testWidgets('水贴按实际内容分栏，rail=$rail', (tester) async {
      auditFeedRail = rail;
      auditFeedSize = GoldenViewports.tabletBoundary840x1024;
      final page = await _pumpFeed(tester,
          timePosts: [_post(100, '平板测试帖 100', DateTime(2026, 10, 8))]);
      await tester.tap(find.text('最新').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('平板测试帖 100').first);
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<PostDetailScreen>(find.byType(PostDetailScreen))
              .hideBackButton,
          !rail);
      expect(
          tester
              .getSize(find.byKey(const ValueKey('post-reply-input-container')))
              .width,
          greaterThan(300));
      expect(tester.takeException(), isNull);
      await _dispose(tester, page);
    });
  }
  testWidgets('水贴分栏收窄后保留详情、回复草稿及焦点，返回可恢复列表', (tester) async {
    auditFeedRail = false;
    auditFeedSize = GoldenViewports.tabletLandscape1280x800;
    final page = await _pumpFeed(tester,
        timePosts: [_post(100, '平板测试帖 100', DateTime(2026, 10, 8))]);
    await tester.tap(find.text('最新').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('平板测试帖 100').first);
    await tester.pumpAndSettle();
    final detailState = tester.state(find.byType(PostDetailScreen));
    final input = find.byKey(const ValueKey('post-reply-input'));
    await tester.enterText(input, 'Pad 回复草稿');
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    for (final size in [
      GoldenViewports.tabletSplit600x800,
      GoldenViewports.tabletLandscape1280x800,
      GoldenViewports.tabletPortrait834x1194
    ]) {
      await setGoldenViewport(tester, size);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(PostDetailScreen)), same(detailState));
      final field = tester.widget<TextField>(input);
      expect(field.controller!.text, 'Pad 回复草稿');
      expect(field.focusNode!.hasFocus, isTrue);
      expect(
          tester
              .getRect(find.byKey(const ValueKey('post-reply-input-container')))
              .bottom,
          lessThanOrEqualTo(size.height - 240));
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(PostDetailScreen), findsNothing);
    expect(find.text('平板测试帖 100'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);
    await _dispose(tester, page);
  });
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
