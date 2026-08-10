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
  testWidgets('Feed 中部横滑切换 mode', (tester) async {
    final page = await _pumpFeed(tester);

    // 默认「综合」(index 1)，向左横滑应切到「精华」(index 2)。
    await tester.dragFrom(const Offset(300, 400), const Offset(-160, 0));
    await tester.pumpAndSettle();

    expect(_modeWeight(tester, '精华'), FontWeight.w600);
    expect(_modeWeight(tester, '综合'), FontWeight.w500);

    await _disposeFeed(tester, page);
  });

  testWidgets('Feed 底部 120px 区域横滑仍可切换 mode', (tester) async {
    final page = await _pumpFeed(tester);

    // 屏幕高度 800，底部 120px 即 y >= 680。旧行为在这里拒绝 mode 横滑。
    await tester.dragFrom(const Offset(300, 760), const Offset(-160, 0));
    await tester.pumpAndSettle();

    expect(_modeWeight(tester, '精华'), FontWeight.w600);
    expect(_modeWeight(tester, '综合'), FontWeight.w500);

    await _disposeFeed(tester, page);
  });
}

FontWeight? _modeWeight(WidgetTester tester, String label) {
  return tester.widget<Text>(find.text(label)).style?.fontWeight;
}

Future<_FeedTestPage> _pumpFeed(WidgetTester tester) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: options.path == '/posts'
                ? <String, dynamic>{
                    'posts': <dynamic>[],
                    'pinned_posts': <dynamic>[],
                    'total': 0,
                  }
                : <dynamic>[],
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
