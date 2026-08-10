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

class _FeedAuthProvider extends ChangeNotifier implements AuthProvider {
  _FeedAuthProvider({required this.client});

  final Dio client;

  @override
  User? get user => null;

  @override
  bool get isLoggedIn => false;

  @override
  int get sessionGeneration => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 前 [firstCount] 次 /posts 请求返回旧帖，之后返回新帖。
Dio _feedDio({required int firstCount}) {
  var postsRequestCount = 0;
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/posts') {
          postsRequestCount++;
          final isFresh = postsRequestCount > firstCount;
          final baseId = isFresh ? 100 : 1;
          final label = isFresh ? '新帖' : '帖子';
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'posts': [
                  for (var i = 0; i < 20; i++)
                    <String, dynamic>{
                      'id': baseId + i,
                      'title': '$label ${baseId + i}',
                      'content': '内容 ${baseId + i}',
                      'board_id': 1,
                      'author_id': 1,
                      'created_at': '2026-08-01T00:00:00Z',
                    },
                ],
                'pinned_posts': <dynamic>[],
                'total': 20,
              },
            ),
          );
          return;
        }
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: <dynamic>[]),
        );
      },
    ),
  );
  return dio;
}

Future<_FreshnessPage> _pumpFeed(
  WidgetTester tester, {
  required int firstCount,
}) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dio = _feedDio(firstCount: firstCount);
  final auth = _FeedAuthProvider(client: dio);
  final postProvider = PostProvider(dio, enableCache: false);
  final messageProvider = MessageProvider(Dio());
  final themeProvider = ThemeProvider(loadOnStart: false);
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
      child: const MaterialApp(home: ShuitieScreen()),
    ),
  );
  await tester.pumpAndSettle();

  return _FreshnessPage(
    auth: auth,
    postProvider: postProvider,
    messageProvider: messageProvider,
    themeProvider: themeProvider,
    sectionProvider: sectionProvider,
  );
}

Future<void> _dispose(WidgetTester tester, _FreshnessPage page) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  page.auth.dispose();
  page.postProvider.dispose();
  page.messageProvider.dispose();
  page.themeProvider.dispose();
  page.sectionProvider.dispose();
}

void main() {
  testWidgets('列表已向下滚动时后台探测不打断阅读，显示内容有更新浮条', (tester) async {
    final page = await _pumpFeed(tester, firstCount: 1);

    // 初始列表为旧帖。
    expect(find.text('帖子 1'), findsOneWidget);

    // 向上滚动列表（阅读位置离开顶部）。
    await tester.dragFrom(const Offset(200, 600), const Offset(0, -400));
    await tester.pumpAndSettle();

    // 触发 60s 自动刷新 → 现在是探测语义。
    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();

    // 阅读位置不被替换：旧帖仍在，新帖未出现。
    expect(find.text('新帖 100'), findsNothing);
    expect(find.text('帖子 1'), findsNothing); // 已滚出顶部
    expect(find.text('帖子 6'), findsOneWidget); // 当前位置内容未变

    // 浮条出现。
    final banner = find.byKey(const ValueKey('feed-freshness-banner'));
    expect(banner, findsOneWidget);

    // 点击浮条：应用新快照并回到顶部。
    await tester.tap(banner);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('feed-freshness-banner')), findsNothing);
    expect(find.text('新帖 100'), findsOneWidget, reason: '点击后应应用新内容并回顶');

    await _dispose(tester, page);
  });

  testWidgets('列表在顶部时后台探测直接温和应用，不显示浮条', (tester) async {
    final page = await _pumpFeed(tester, firstCount: 1);

    expect(find.text('帖子 1'), findsOneWidget);

    await tester.pump(const Duration(seconds: 61));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('feed-freshness-banner')), findsNothing);
    expect(find.text('新帖 100'), findsOneWidget, reason: '顶部应直接应用新内容');

    await _dispose(tester, page);
  });

  testWidgets('下拉手动刷新仍立即应用且不出现浮条', (tester) async {
    final page = await _pumpFeed(tester, firstCount: 1);

    expect(find.text('帖子 1'), findsOneWidget);

    // 下拉触发 RefreshIndicator。
    await tester.dragFrom(const Offset(200, 200), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(find.text('新帖 100'), findsOneWidget, reason: '手动刷新应直接应用');
    expect(find.byKey(const ValueKey('feed-freshness-banner')), findsNothing);

    await _dispose(tester, page);
  });
}

class _FreshnessPage {
  const _FreshnessPage({
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
