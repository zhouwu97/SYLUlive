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
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/widgets/ai/admin_ai_control_sheet.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/global_background_wrapper.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final path = Platform.environment['DARK_CLEAN_QA_DIR'];
  if (path == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(path).create(recursive: true);
      await File('$path/$name.png').writeAsBytes(data.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  for (final dark in [false, true]) {
    testWidgets('淡色渐变保留语义色和几何，简洁模式不放大饱和度 dark=$dark', (tester) async {
      final settings = ThemeProvider(loadOnStart: false);
      addTearDown(settings.dispose);
      await settings.setBackgroundImage('morenbeijing.jpeg');
      await settings.setFrostedGlass(true);
      const colors = [Color(0x146366F1), Color(0x0A8B5CF6)];
      const gradients = <Gradient>[
        LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: colors,
            stops: [.2, .8],
            tileMode: TileMode.mirror),
        RadialGradient(
            center: Alignment.topLeft,
            radius: .7,
            focal: Alignment.center,
            focalRadius: .1,
            colors: colors),
        SweepGradient(
            center: Alignment.bottomRight,
            startAngle: .2,
            endAngle: 4,
            colors: colors),
      ];
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: settings,
        child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            home: Scaffold(
                body: Column(children: [
              for (var i = 0; i < gradients.length; i++)
                AppCardSurface(
                    key: ValueKey('gradient-$i'),
                    height: 60,
                    decoration: BoxDecoration(gradient: gradients[i]),
                    child: const Text('渐变卡片')),
            ]))),
      ));
      final base = dark
          ? AppColors.surfaceSecondaryDark
          : AppColors.surfaceSecondaryLight;
      Future<void> check(double opacity) async {
        await tester.pumpAndSettle();
        for (var i = 0; i < gradients.length; i++) {
          final actual = tester
              .widgetList<Container>(find.descendant(
                  of: find.byKey(ValueKey('gradient-$i')),
                  matching: find.byType(Container)))
              .map((w) => w.decoration)
              .whereType<BoxDecoration>()
              .map((d) => d.gradient)
              .whereType<Gradient>()
              .single;
          expect(actual.runtimeType, gradients[i].runtimeType);
          for (var stop = 0; stop < colors.length; stop++) {
            expect(
                actual.colors[stop],
                Color.alphaBlend(colors[stop], base)
                    .withValues(alpha: opacity));
          }
          if (actual is LinearGradient) {
            expect(actual.begin, Alignment.topRight);
            expect(actual.stops, [.2, .8]);
            expect(actual.tileMode, TileMode.mirror);
          }
        }
      }

      await check(.7);
      await settings.setComponentOpacity(.35);
      await check(.35);
      await settings.setCleanBackgroundMode();
      await check(1);
      expect(settings.backgroundImage, 'morenbeijing.jpeg');
      await settings.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final large in [false, true]) {
    testWidgets('AI 调用状态在明暗／背景模式间切换，加载失败重试可读 large=$large', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone390x844);
      final settings = ThemeProvider(loadOnStart: false);
      final auth = AuthProvider(Dio(), loadStoredAuth: false);
      addTearDown(settings.dispose);
      addTearDown(auth.dispose);
      await settings.setBackgroundImage('morenbeijing.jpeg');
      await settings.setDarkMode(true);
      await settings.setFrostedGlass(true);
      var fail = true;
      final gate = Completer<void>();
      final dio = Dio()
        ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
          await gate.future;
          if (fail) {
            h.reject(DioException(
                requestOptions: o,
                response: Response(requestOptions: o, statusCode: 503)));
          } else {
            h.resolve(Response(requestOptions: o, statusCode: 200, data: {
              'requests': 3,
              'success_rate': 1.0,
              'input_output_tokens': 100
            }));
          }
        }));
      final capture = GlobalKey();
      await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>.value(value: settings),
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ],
          child: Consumer<ThemeProvider>(
              builder: (_, theme, __) => RepaintBoundary(
                    key: capture,
                    child: GoldenTestApp(
                        themeMode: theme.themeMode,
                        textScaler: large
                            ? GoldenTextProfile.large.scaler
                            : TextScaler.noScaling,
                        home: GlobalBackgroundWrapper(
                            child: Scaffold(
                                backgroundColor: Colors.transparent,
                                body: AdminAiControlSheet(dio: dio)))),
                  ))));
      await tester.pump();
      expect(find.text('检查中'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('状态未知'), findsOneWidget);
      expect(find.textContaining('生产指标暂不可用'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('生产在线'), findsOneWidget);
      for (final dark in [true, false]) {
        await settings.setDarkMode(dark);
        for (final custom in [false, true]) {
          if (custom) {
            await settings.trySetCustomBackgroundMode();
          } else {
            await settings.setCleanBackgroundMode();
          }
          await tester.pumpAndSettle();
          final status = find
              .ancestor(
                  of: find.text('AI Runtime 状态'),
                  matching: find.byType(AppCardSurface))
              .first;
          final color = (tester.widget<AppCardSurface>(status).decoration!
                  as BoxDecoration)
              .color!;
          expect(
              color.computeLuminance(), dark ? lessThan(.1) : greaterThan(.8));
          expect(find.byType(Image), custom ? findsWidgets : findsNothing,
              reason: '简洁模式不能继续显示已保存的壁纸');
          await _capture(tester, capture,
              'ai-${dark ? 'dark' : 'light'}-${custom ? 'custom' : 'clean'}-$large');
          expect(tester.takeException(), isNull);
        }
      }
      expect(settings.backgroundImage, 'morenbeijing.jpeg');
      await settings.setFrostedGlass(false);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
