import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/app_bootstrap.dart' show getSharedDio;
import 'package:shenliyuan/models/edu_academic_situation.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/canteen_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/appeal_create_screen.dart';
import 'package:shenliyuan/screens/canteen_dish_list_screen.dart';
import 'package:shenliyuan/screens/court_hub_screen.dart';
import 'package:shenliyuan/screens/edu_academic_course_detail_screen.dart';
import 'package:shenliyuan/theme/app_colors.dart';
import 'package:shenliyuan/theme/app_radius.dart';
import 'package:shenliyuan/widgets/app_card.dart';
import 'package:shenliyuan/widgets/app_input_surface.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/mock_public_image_http.dart';

void _expectInsideRoundedSurface(
    WidgetTester tester, Finder text, Finder card) {
  final rect = tester.getRect(text);
  final path = Path()
    ..addRRect(RRect.fromRectAndRadius(
        tester.getRect(card), const Radius.circular(AppRadius.lg)));
  for (final point in [
    rect.topLeft + const Offset(.5, .5),
    rect.topRight + const Offset(-.5, .5),
    rect.bottomLeft + const Offset(.5, -.5),
    rect.bottomRight + const Offset(-.5, -.5),
  ]) {
    expect(path.contains(point), isTrue, reason: '卡片文字须完整保留在圆角内');
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final output = Platform.environment['CARD_AUDIT_QA_DIR'];
  if (output == null) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() async {
    AppPreferencesStore.setMockInitialValues({});
    await installMockPublicImageHttp();
  });
  tearDown(uninstallMockPublicImageHttp);

  for (final profile in ['light', 'dark', 'large-text', 'stress']) {
    for (final scene in ['course', 'appeal', 'dishes', 'court-error']) {
      testWidgets('$scene $profile 底面圆角、标题与文字安全区', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        final gate = Completer<void>();
        var failCourt = true;
        final interceptor =
            InterceptorsWrapper(onRequest: (request, handler) async {
          if (!request.path.startsWith('/appeals') || request.method != 'GET') {
            handler.reject(DioException(requestOptions: request));
          } else if (failCourt) {
            await gate.future;
            handler.reject(DioException(requestOptions: request));
          } else {
            handler.resolve(Response(
                requestOptions: request,
                statusCode: 200,
                data: {'appeals': <Object>[]}));
          }
        });
        if (scene == 'court-error') {
          getSharedDio().interceptors.insert(0, interceptor);
          addTearDown(() => getSharedDio().interceptors.remove(interceptor));
        }
        final dio = Dio()
          ..interceptors.add(InterceptorsWrapper(
            onRequest: (request, handler) => handler.resolve(Response(
              requestOptions: request,
              statusCode: 200,
              data: [
                {
                  'id': 7,
                  'name': '测试菜品',
                  'cover_image': '/uploads/audit.png',
                  'photo_count': 3,
                  'last_photo_at': '2026-11-03'
                }
              ],
            )),
          ));
        final capture = GlobalKey();
        await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: appearance),
            ChangeNotifierProvider(create: (_) => CanteenProvider(dio)),
          ],
          child: RepaintBoundary(
            key: capture,
            child: GoldenTestApp(
              themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
              textScaler: TextScaler.linear(profile == 'stress'
                  ? 1.5
                  : profile == 'large-text'
                      ? 1.3
                      : 1),
              home: switch (scene) {
                'course' => EduAcademicCourseDetailScreen(
                      course: EduAcademicCourse.fromJson({
                    'course_name': '卡片检查课程',
                    'course_code': 'TEST',
                    'credits': 3,
                    'grade': '95'
                  })),
                'appeal' => const AppealCreateScreen(
                    reportId: 1, governanceReason: '本地验收的原治理说明'),
                'dishes' => const CanteenDishListScreen(
                    canteenId: 1, canteenName: '测试商家'),
                _ => const CourtHubScreen(),
              },
            ),
          ),
        ));
        await tester.pump();
        if (scene == 'court-error') {
          expect(find.byType(CircularProgressIndicator), findsWidgets);
          gate.complete();
        }
        await tester.pumpAndSettle();
        final wallpaper = tester.widget<Image>(find.byType(Image).first).image;
        await tester
            .runAsync(() => precacheImage(wallpaper, capture.currentContext!));
        for (var frame = 0; frame < 3; frame++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 20));
        }
        await tester.pumpAndSettle();
        final content = switch (scene) {
          'course' => find.text('最大成绩'),
          'appeal' => find.text('本地验收的原治理说明'),
          'dishes' => find.text('3 张实拍'),
          _ => find.text('重试'),
        };
        final surface = find
            .ancestor(of: content, matching: find.byType(AppCardSurface))
            .first;
        expect(
            (tester.widget<AppCardSurface>(surface).decoration!
                    as BoxDecoration)
                .borderRadius,
            BorderRadius.circular(AppRadius.lg));
        _expectInsideRoundedSurface(tester, content, surface);
        if (scene == 'court-error') {
          _expectInsideRoundedSurface(
              tester,
              find.descendant(of: surface, matching: find.byType(Text)).first,
              surface);
        }
        if (scene == 'course' || scene == 'appeal') {
          expect(
              find.ancestor(
                  of: find.text(scene == 'course' ? '卡片检查课程' : '原治理决定'),
                  matching: find.byType(AppCardSurface)),
              findsNothing);
        }
        final rect = tester.getRect(surface);
        Rect? inputRect;
        if (scene == 'appeal') {
          final field = find.byType(TextField);
          expect(
              find.ancestor(of: field, matching: find.byType(AppInputSurface)),
              findsOneWidget);
          await tester.enterText(field, '本地验证草稿');
          await tester.pumpAndSettle();
          inputRect = tester.getRect(field);
        }
        for (final glass in [false, true, false]) {
          await appearance.setFrostedGlass(glass);
          await tester.pumpAndSettle();
          expect(tester.getRect(surface), rect);
          if (scene == 'appeal') {
            final field = find.byType(TextField);
            expect(tester.widget<TextField>(field).controller!.text, '本地验证草稿');
            expect(tester.getRect(field), inputRect);
          }
          _expectInsideRoundedSurface(tester, content, surface);
          if (!glass) {
            final decoration = tester
                .widget<DecoratedBox>(find
                    .descendant(
                        of: surface, matching: find.byType(DecoratedBox))
                    .first)
                .decoration as BoxDecoration;
            expect(
                decoration.color,
                profile == 'dark'
                    ? AppColors.surfaceSecondaryDark
                    : AppColors.surfaceSecondaryLight);
          }
          await _capture(
              tester, capture, '$scene-$profile-${glass ? 'glass' : 'solid'}');
        }
        if (scene == 'court-error') {
          failCourt = false;
          await tester.tap(find.text('重试'));
          await tester.pumpAndSettle();
          expect(find.text('暂时没有待你陪审的案件'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        if (scene == 'dishes') await flushMockPublicImageTimers(tester);
      });
    }
  }
}
