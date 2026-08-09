import 'dart:async';

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
  _FeedAuthProvider({required this.client, required this.loggedIn});

  final Dio client;
  final bool loggedIn;

  @override
  User? get user => null;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  int get sessionGeneration => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('feed keeps loading state while the first request is pending',
      (tester) async {
    final gate = Completer<void>();
    final page = await _pumpFeed(tester, gate: gate);
    await _pumpFrames(tester, count: 4);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete();
    await _pumpFrames(tester);
    await _disposeFeed(tester, page);
  });

  testWidgets('feed exposes an actionable error state', (tester) async {
    final page = await _pumpFeed(tester, fail: true);
    await _pumpFrames(tester);

    expect(page.postProvider.errorFor(1, sort: 'all'), isNotNull);
    expect(find.text('帖子加载失败'), findsOneWidget);
    expect(find.text('刷新试试'), findsOneWidget);
    await _disposeFeed(tester, page);
  });

  testWidgets('feed keeps the empty state distinct from loading and error',
      (tester) async {
    final page = await _pumpFeed(tester);
    await _pumpFrames(tester);

    expect(find.text('暂无帖子'), findsOneWidget);
    expect(find.text('帖子加载失败'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _disposeFeed(tester, page);
  });

  testWidgets('following feed shows the unlogged-in guard', (tester) async {
    final page = await _pumpFeed(tester);
    await _pumpFrames(tester);

    await tester.tap(find.text('关注'));
    await tester.pump(const Duration(milliseconds: 160));

    expect(find.text('登录后查看关注动态'), findsOneWidget);
    expect(find.text('去登录'), findsOneWidget);
    await _disposeFeed(tester, page);
  });
}

Future<_FeedTestPage> _pumpFeed(
  WidgetTester tester, {
  Completer<void>? gate,
  bool fail = false,
}) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (options.path == '/posts') {
          if (gate != null) await gate.future;
          if (fail) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: 'offline',
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'posts': <dynamic>[],
                'pinned_posts': <dynamic>[],
                'total': 0,
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

  final auth = _FeedAuthProvider(client: dio, loggedIn: false);
  final postProvider = PostProvider(dio, enableCache: false);
  final messageProvider = MessageProvider(Dio());
  final themeProvider = ThemeProvider(loadOnStart: false);
  final sectionProvider = WaterSectionProvider(null);
  final widget = MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<PostProvider>.value(value: postProvider),
      ChangeNotifierProvider<MessageProvider>.value(value: messageProvider),
      ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
      ChangeNotifierProvider<WaterSectionProvider>.value(
          value: sectionProvider),
    ],
    child: const MaterialApp(home: ShuitieScreen()),
  );
  await tester.pumpWidget(widget);
  await tester.pump();
  return _FeedTestPage(
    auth: auth,
    postProvider: postProvider,
    messageProvider: messageProvider,
    themeProvider: themeProvider,
    sectionProvider: sectionProvider,
  );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 8}) async {
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _disposeFeed(WidgetTester tester, _FeedTestPage page) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  page.auth.dispose();
  page.postProvider.dispose();
  page.messageProvider.dispose();
  page.themeProvider.dispose();
  page.sectionProvider.dispose();
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
