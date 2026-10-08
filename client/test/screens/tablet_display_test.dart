import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/post_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/ai/ai_assistant_screen.dart';
import 'package:shenliyuan/screens/canteen_dish_list_screen.dart';
import 'package:shenliyuan/screens/login_screen.dart';
import 'package:shenliyuan/screens/market_screen.dart';
import 'package:shenliyuan/widgets/market_post_card.dart';
import 'package:shenliyuan/widgets/responsive_content.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';
import 'ai/ai_assistant_screen_test.dart' as ai;

// 本机保存证据图时显式开启；CI 只执行行为和几何断言，不更新 canonical。
const _capture = bool.fromEnvironment('TABLET_CAPTURE');

Future<void> _capturePage(
    WidgetTester tester, GlobalKey key, String name) async {
  if (!_capture) return;
  final boundary =
      key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('build/tablet-fixes');
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png')
        .writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

Dio _fixtureDio(String screen) {
  final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    handler.resolve(Response(
      requestOptions: options,
      statusCode: 200,
      data: screen == 'dishes'
          ? [
              for (var i = 1; i <= 12; i++)
                {
                  'id': i,
                  'name': '测试菜品 $i',
                  'cover_image': '/fixture-$i.png',
                  'photo_count': 2
                },
            ]
          : {
              'posts': [
                for (var i = 1; i <= 12; i++)
                  {
                    'id': i,
                    'title': '测试商品 $i',
                    'content': '用于观察平板列表密度',
                    'board_id': 2,
                    'post_type': 'sell',
                    'author_id': 1,
                    'status': 'normal',
                    'price': 99,
                    'created_at': '2026-10-01T08:00:00Z'
                  },
              ],
              'total': 12,
              'session_id': null,
            },
    ));
  }));
  return dio;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  for (final profile in <(Size, double, ThemeMode)>[
    (GoldenViewports.tabletSplit600x800, 1.3, ThemeMode.dark),
    (GoldenViewports.tabletPortrait768x1024, 1, ThemeMode.light),
    (GoldenViewports.tabletPortrait834x1194, 1, ThemeMode.light),
    (GoldenViewports.tabletBoundary839x1024, 1, ThemeMode.light),
    (GoldenViewports.tabletBoundary840x1024, 1, ThemeMode.light),
    (GoldenViewports.tabletLandscape1024x768, 1.5, ThemeMode.dark),
    (GoldenViewports.tabletLandscape1280x800, 1, ThemeMode.light),
  ]) {
    for (final screen in ['dishes', 'market', 'ai', 'login']) {
      testWidgets('$screen Pad ${profile.$1.width.toInt()} / ${profile.$2}×',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        await setGoldenViewport(tester, profile.$1);
        final boundaryKey = GlobalKey();
        final dio = _fixtureDio(screen);
        Widget page;
        if (screen == 'dishes') {
          page = ChangeNotifierProvider(
              create: (_) => CanteenProvider(dio),
              child: const CanteenDishListScreen(
                  canteenId: 1, canteenName: '测试食堂'));
        } else if (screen == 'ai') {
          page = MultiProvider(
              providers: [
                ChangeNotifierProvider<AuthProvider>.value(
                    value: ai.FakeAuthProvider()),
                ChangeNotifierProvider<EduProvider>.value(
                    value: ai.FakeEduProvider()),
              ],
              child: AiAssistantScreen(
                  service: ai.FakeAiAssistantService(),
                  dio: dio,
                  capabilities: AiCapabilities.fromJson({
                    'enabled': true,
                    'access_allowed': true,
                    'chat_enabled': true,
                    'quota': {
                      'limit': 20,
                      'remaining': 20,
                      'window_seconds': 3600
                    }
                  })));
        } else if (screen == 'login') {
          page = ChangeNotifierProvider(
              create: (_) => AuthProvider(dio, loadStoredAuth: false),
              child: const LoginScreen());
        } else {
          page = MultiProvider(providers: [
            ChangeNotifierProvider<AuthProvider>(
                create: (_) => AuthProvider(dio, loadStoredAuth: false)),
            ChangeNotifierProvider(
                create: (_) => PostProvider(dio, enableCache: false)),
            ChangeNotifierProvider(
                create: (_) => ThemeProvider(loadOnStart: false)),
          ], child: const MarketScreen());
        }
        await tester.pumpWidget(GoldenTestApp(
            themeMode: profile.$3,
            textScaler: TextScaler.linear(profile.$2),
            home: RepaintBoundary(key: boundaryKey, child: page)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (screen == 'dishes') {
          final first = tester.getRect(find.text('测试菜品 1'));
          final second = tester.getRect(find.text('测试菜品 2'));
          expect(first.width, lessThanOrEqualTo(320));
          expect(first.top, second.top);
          if (profile.$1.width >= 768) {
            expect(tester.getRect(find.text('测试菜品 3')).top, first.top);
          }
        } else if (screen == 'market') {
          expect(tester.getSize(find.byType(MarketPostCard).first).width,
              lessThanOrEqualTo(320));
        } else {
          final content = tester.getRect(find
              .descendant(
                of: find.byType(ResponsiveContent),
                matching: find.byType(ConstrainedBox),
              )
              .first);
          expect(content.width, lessThanOrEqualTo(screen == 'ai' ? 840 : 680));
          expect(content.center.dx, closeTo(profile.$1.width / 2, 0.1));
          if (screen == 'ai') {
            await tester.tap(find.text('学业风险'));
            await tester.pump();
            expect(
                tester
                    .widget<TextField>(find.byType(TextField))
                    .controller!
                    .text,
                contains('分析我的学业'));
          } else {
            await tester.enterText(
                find.byType(TextField).first, 'pad@example.test');
            await tester.pumpAndSettle();
            expect(
                tester
                    .widget<TextField>(find.byType(TextField).first)
                    .controller!
                    .text,
                'pad@example.test');
          }
        }
        await _capturePage(
            tester, boundaryKey, '$screen-${profile.$1.width.toInt()}');
        if (screen == 'ai') {
          await tester.tap(find.text('个人助手'));
          await tester.pumpAndSettle();
          expect(find.text('竞赛搜索'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await _capturePage(
              tester, boundaryKey, 'ai-personal-${profile.$1.width.toInt()}');
        }
        if (screen == 'login' && profile.$1.width > 680) {
          final editable = find.descendant(
              of: find.byType(TextField).first,
              matching: find.byType(EditableText));
          expect(
              tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
          await tester.tapAt(Offset(16, profile.$1.height / 2));
          await tester.pumpAndSettle();
          expect(tester.widget<EditableText>(editable).focusNode.hasFocus,
              isFalse);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
      });
    }
  }
}
