import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/canteen_discovery_provider.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/canteen_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/mock_public_image_http.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  setUp(installMockPublicImageHttp);
  tearDown(uninstallMockPublicImageHttp);
  for (final profile in ['light', 'dark', 'large-text']) {
    testWidgets('餐饮 $profile 搜索、今日统计、热门菜品使用一致玻璃，关闭恢复', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(theme.dispose);
      await theme.setBackgroundImage('morenbeijing.jpeg', fillScreen: false);
      await theme.setFrostedGlass(true);
      await theme.setComponentOpacity(.7);
      final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: {
          'hero': {
            'canteen_id': 1,
            'canteen_name': '测试商家',
            'rating_count': 3,
            'dimension_scores': {'taste': 4.8, 'value': 4.5, 'queue': 4.6}
          },
          'ranking_entry': {'total': 1},
          'today_effective_reviewer_count': 3,
          'hot_dishes': [
            {
              'id': 11,
              'name': '测试菜品',
              'canteen_id': 1,
              'canteen_name': '测试商家',
              'cover_image': '/uploads/fixture.jpg',
              'photo_count': 1,
              'average_score': 4.8
            }
          ],
          'recent_reviews': [],
        }));
      }));
      final capture = GlobalKey();
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: theme),
            ChangeNotifierProvider(
                create: (_) => CanteenDiscoveryProvider(dio)),
            ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
            ChangeNotifierProvider(
                create: (_) => AuthProvider(dio, loadStoredAuth: false)),
          ],
          child: RepaintBoundary(
              key: capture,
              child: GoldenTestApp(
                themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
                textScaler: profile == 'large-text'
                    ? GoldenTextProfile.large.scaler
                    : TextScaler.noScaling,
                home: const CanteenScreen(),
              ))));
      await tester.pumpAndSettle();
      final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
      await tester
          .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
      await tester.pumpAndSettle();
      final search = find.ancestor(
          of: find.byType(TextField), matching: find.byType(AppCardSurface));
      final today = find.byKey(const Key('canteen_today_review_card'));
      expect(search, findsOneWidget);
      expect((tester.getCenter(find.descendant(of: find.byType(TextField), matching: find.byType(EditableText))).dy -
          tester.getCenter(search).dy).abs(), lessThanOrEqualTo(1));
      expect(
          tester.widget<TextField>(find.byType(TextField)).decoration!.filled,
          isFalse);
      expect(tester.widget(today), isA<AppCardSurface>());
      for (final card in [search, today]) {
        expect(find.descendant(of: card, matching: find.byType(BackdropFilter)),
            findsOneWidget);
      }
      await tester.ensureVisible(find.text('测试菜品'));
      await tester.pumpAndSettle();
      final dish = find
          .ancestor(
              of: find.text('测试菜品'), matching: find.byType(AppCardSurface))
          .first;
      final dishPixels = find.descendant(of: dish, matching: find.byType(RawImage));
      await driveMockPublicImageLoads(tester, windows: 50,
          until: () => tester.widgetList<RawImage>(dishPixels).any((w) => w.image != null));
      expect(tester.widgetList<RawImage>(dishPixels).any((w) => w.image != null), isTrue,
          reason: '等待实拍图片的真实缓存与解码链完成，再采样和清理缓存计时器');
      expect(find.descendant(of: dish, matching: find.byType(BackdropFilter)),
          findsOneWidget);
      final rect = tester.getRect(dish);
      final filter = tester.getRect(
          find.descendant(of: dish, matching: find.byType(BackdropFilter)));
      expect(filter, rect, reason: '封面与正文使用同一完整材质区域');

      final dir = Platform.environment['BACKGROUND_QA_DIR'];
      if (dir != null) {
        await tester.runAsync(() async {
          final boundary = capture.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final image = await boundary.toImage();
          try {
            await Directory(dir).create(recursive: true);
            final data =
                (await image.toByteData(format: ui.ImageByteFormat.png))!;
            await File('$dir/canteen-$profile.png')
                .writeAsBytes(data.buffer.asUint8List());
          } finally {
            image.dispose();
          }
        });
      }
      await theme.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      await theme.setCleanBackgroundMode();
      await tester.pumpAndSettle();
      expect(theme.backgroundImage, 'morenbeijing.jpeg');
      await tester.pumpWidget(const SizedBox.shrink());
      await flushMockPublicImageTimers(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
