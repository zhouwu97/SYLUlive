import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/campus_screen.dart';
import 'package:shenliyuan/screens/market_screen.dart';
import 'package:shenliyuan/services/ai_assistant_service.dart';
import 'package:shenliyuan/services/campus_article_service.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _Api {
  final dio = Dio();
  Completer<void>? pending;
  bool fail = false;
  bool empty = false;

  _Api() {
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      await pending?.future;
      if (fail) {
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ));
        return;
      }
      final article = {
        'id': 1,
        'title': '校园通知测试',
        'category': '教务通知',
        'publish_date': '2026-10-25',
      };
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: switch (options.path) {
          '/campus/articles/latest' => {'item': empty ? null : article},
          '/campus/articles' => {
              'items': empty ? [] : [article],
              'page': 1,
              'page_size': 6,
              'has_more': false,
            },
          '/ai/capabilities' => {'enabled': false},
          _ => {
              'posts': empty
                  ? []
                  : [
                      {
                        'id': 1,
                        'title': '闲置自行车测试',
                        'content': '正常使用',
                        'board_id': 2,
                        'author_id': 1,
                        'post_type': 'sell',
                        'price': 99,
                        'created_at': '2026-10-25T08:00:00Z',
                      }
                    ],
              'total': empty ? 0 : 1,
            },
        },
      ));
    }));
  }
}

Future<Color> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData())!;
      // 页面左侧空白边缘必须透出壁纸，不能只检查 Image 在树中存在。
      final offset = (400 * image.width + 2) * 4;
      final color = Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
      final dir = Platform.environment['BACKGROUND_QA_DIR'];
      if (dir != null) {
        await Directory(dir).create(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$dir/$name.png').writeAsBytes(png.buffer.asUint8List());
      }
      return color;
    } finally {
      image.dispose();
    }
  }))!;
}

Widget _screen(_Api api, bool market) => market
    ? const MarketScreen()
    : CampusScreen(
        articleService: CampusArticleService(api.dio),
        aiService: AiAssistantService(api.dio),
        nowProvider: () => DateTime(2026, 10, 25),
      );

Widget _providers(_Api api, ThemeProvider theme, Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: theme),
        ChangeNotifierProvider(
            create: (_) => AuthProvider(api.dio, loadStoredAuth: false)),
        ChangeNotifierProvider(
            create: (_) => PostProvider(api.dio, enableCache: false)),
      ],
      child: child,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final market in [true, false]) {
    final page = market ? 'market' : 'campus';
    testWidgets('$page 加载中切换背景，失败重试与空数据均保留背景', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      final api = _Api()..pending = Completer<void>();
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: true);
      final capture = GlobalKey();
      await tester.pumpWidget(_providers(
          api,
          theme,
          GoldenTestApp(
            home: RepaintBoundary(
                key: capture,
                child: GlobalBackgroundWrapper(
                  child: _screen(api, market),
                )),
          )));
      await tester.pump(const Duration(milliseconds: 100));
      await theme.setCleanBackgroundMode();
      await tester.pump();
      expect(await _capture(tester, capture, '$page-loading-clean'),
          kCleanWarmBackgroundLight);
      await theme.trySetCustomBackgroundMode();
      await tester.pump();
      api.fail = true;
      api.pending!.complete();
      api.pending = null;
      await tester.pumpAndSettle();
      final retry = find.text(market ? '重试' : '点击重试');
      expect(retry, findsOneWidget);
      expect(await _capture(tester, capture, '$page-error'),
          isNot(kCleanWarmBackgroundLight));
      api.fail = false;
      api.empty = true;
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.text(market ? '还没有商品' : '暂无校园资讯'), findsWidgets);
      expect(await _capture(tester, capture, '$page-empty'),
          isNot(kCleanWarmBackgroundLight));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
    for (final profile in ['light', 'dark', 'large-text']) {
      testWidgets('$page $profile 背景切换保留内容并实际透出壁纸', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone360x800);
        final api = _Api();
        final theme = ThemeProvider(loadOnStart: false);
        await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: true);
        await theme.setFrostedGlass(true);
        await theme.setComponentOpacity(0.7);
        addTearDown(theme.dispose);
        final capture = GlobalKey();
        await tester.pumpWidget(_providers(
          api,
          theme,
          GoldenTestApp(
            themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
            textScaler: profile == 'large-text'
                ? GoldenTextProfile.large.scaler
                : TextScaler.noScaling,
            home: RepaintBoundary(
              key: capture,
              child: GlobalBackgroundWrapper(
                child: _screen(api, market),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        // 真实资源解码在 fakeAsync 之外完成。
        await tester.runAsync(() async {
          await precacheImage(
              const AssetImage('assets/images/morenbeijing.jpeg'),
              capture.currentContext!);
        });
        await tester.pumpAndSettle();
        final cleanColor = profile == 'dark'
            ? kCleanWarmBackgroundDark
            : kCleanWarmBackgroundLight;
        final customColor =
            await _capture(tester, capture, '$page-$profile-custom');
        expect(customColor, isNot(cleanColor));
        final title = market ? '闲置自行车测试' : '校园通知测试';
        expect(find.text(title), findsOneWidget);

        await theme.setCleanBackgroundMode();
        await tester.pumpAndSettle();
        expect(await _capture(tester, capture, '$page-$profile-clean'),
            cleanColor);
        expect(
            find.descendant(
                of: find.byType(CustomBackgroundLayer),
                matching: find.byType(Image)),
            findsNothing);
        expect(find.text(title), findsOneWidget);

        await theme.trySetCustomBackgroundMode();
        await tester.pumpAndSettle();
        expect(await _capture(tester, capture, '$page-$profile-restored'),
            customColor);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
