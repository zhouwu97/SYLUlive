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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  bool tall = false,
}) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.physicalSize =
      tall ? const Size(400, 3000) : const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dio = _feedDio(timePosts: timePosts);
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

void main() {
  testWidgets('最新 feed 保持服务端顺序，30 天前旧帖仍显示，客户端不二次排序',
      (tester) async {
    final now = DateTime.now();
    // 服务端返回顺序刻意与时间倒序不一致：最新的 id3 在最前，中间夹一条 45 天前旧帖。
    final posts = <Map<String, dynamic>>[
      _post(3, '帖子 3', now.subtract(const Duration(hours: 1))),
      _post(1, '帖子 1', now.subtract(const Duration(days: 45))),
      _post(2, '帖子 2', now.subtract(const Duration(days: 2))),
    ];
    final page = await _pumpFeed(tester, timePosts: posts);

    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();

    // 服务端顺序被原样保留：id3 在 id1 上方，id1 在 id2 上方。
    final y3 = tester.getTopLeft(find.text('帖子 3')).dy;
    final y1 = tester.getTopLeft(find.text('帖子 1')).dy;
    final y2 = tester.getTopLeft(find.text('帖子 2')).dy;
    expect(y3, lessThan(y1), reason: '最新 feed 应按服务端顺序渲染，而非按时间重排');
    expect(y1, lessThan(y2), reason: '最新 feed 应按服务端顺序渲染，而非按时间重排');

    // 45 天前旧帖仍显示：客户端不再做 3 天过滤。
    expect(find.text('帖子 1'), findsOneWidget);

    // 三个帖子的 id 在 provider 中保持服务端顺序（无 take / 无重排）。
    final timePosts = page.postProvider.postsFor(1, sort: 'time');
    expect(timePosts.map((p) => p.id).toList(), [3, 1, 2]);

    await _dispose(tester, page);
  });

  testWidgets('最新 feed 超过 12 条仍全部保留（不做 take(12)）', (tester) async {
    final now = DateTime.now();
    final posts = <Map<String, dynamic>>[
      for (var i = 1; i <= 15; i++)
        _post(i, '帖子 $i', now.subtract(Duration(hours: i))),
    ];
    final page = await _pumpFeed(tester, timePosts: posts, tall: true);

    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();

    // 15 条全部保留：首尾帖子都存在。
    expect(find.text('帖子 1'), findsOneWidget);
    expect(find.text('帖子 12'), findsOneWidget);
    expect(find.text('帖子 13'), findsOneWidget);
    expect(find.text('帖子 15'), findsOneWidget);

    expect(page.postProvider.postsFor(1, sort: 'time').length, 15);

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
