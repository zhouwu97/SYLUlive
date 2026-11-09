import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_evaluation_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/schedule/course_detail_sheet.dart';
import 'package:shenliyuan/widgets/app_card.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';
import '../helpers/active_backdrop_filters.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  for (final dark in [false, true]) {
    for (final glass in [false, true]) {
      for (final opacity in [0.0, 0.55, 1.0]) {
        final label = 'dark=$dark-glass=$glass-opacity=$opacity';
        testWidgets('课程详情保持可读底面 $label', (tester) async {
          await setGoldenViewport(tester, GoldenViewports.phone390x844);
          final appearance = ThemeProvider(loadOnStart: false);
          final schedule = CourseScheduleProvider();
          final auth = AuthProvider(Dio(), loadStoredAuth: false);
          final evaluation = CourseEvaluationProvider(null);
          addTearDown(appearance.dispose);
          addTearDown(schedule.dispose);
          addTearDown(auth.dispose);
          addTearDown(evaluation.dispose);
          await appearance.setBackgroundImage('morenbeijing.jpeg');
          await appearance.trySetCustomBackgroundMode();
          await appearance.setFrostedGlass(glass);
          await appearance.setComponentOpacity(opacity);
          final boundary = GlobalKey();
          const course = CourseBlock(
              id: 1,
              courseCode: '',
              name: '高等数学A1',
              teacher: '测试教师',
              location: 'A-211',
              weekday: 1,
              startSection: 3,
              endSection: 4,
              weeks: [4, 5, 8, 9],
              color: '#448AFF');
          await tester.pumpWidget(MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: appearance),
                ChangeNotifierProvider.value(value: schedule),
                ChangeNotifierProvider.value(value: auth),
                ChangeNotifierProvider.value(value: evaluation),
              ],
              child: RepaintBoundary(
                  key: boundary,
                  child: GoldenTestApp(
                    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                    textScaler: const TextScaler.linear(1.3),
                    home: Builder(
                        builder: (context) => Scaffold(
                                body: Stack(children: [
                              Positioned.fill(
                                  child:
                                      Text(List.filled(120, '底层课表文字 ').join())),
                              Center(
                                  child: FilledButton(
                                      onPressed: () => CourseDetailSheet.show(
                                          context,
                                          course: course,
                                          currentAcademicWeek: 8),
                                      child: const Text('打开课程详情'))),
                            ]))),
                  ))));
          await tester.tap(find.text('打开课程详情'));
          await tester.pumpAndSettle();
          final surface = find
              .ancestor(
                  of: find.text('高等数学A1'),
                  matching: find.byType(AppCardSurface))
              .first;
          final paint = tester
              .widget<DecoratedBox>(find
                  .descendant(of: surface, matching: find.byType(DecoratedBox))
                  .first)
              .decoration as BoxDecoration;
          final expectedAlpha = glass ? opacity : opacity.clamp(0.9, 1.0);
          expect(paint.color!.a, closeTo(expectedAlpha, 0.005),
              reason: '模糊生效时详情底面跟随全局不透明度保留玻璃观感，'
                  '关闭模糊时用可读下限遮住底层课表');
          expect(activeBackdropFilters(),
              glass ? findsOneWidget : findsNothing,
              reason: '毛玻璃开启时详情必须真实模糊背后内容');
          expect(find.text('测试教师'), findsOneWidget);
          expect(find.text('A-211'), findsOneWidget);
          expect(find.text('周一 第3-4节'), findsOneWidget);
          expect(find.text('第4、5、8、9周'), findsOneWidget);
          expect(find.text('调整课程安排').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          final directory = Platform.environment['SCHEDULE_RENDER_EVIDENCE'];
          if (directory != null) {
            await tester.runAsync(() async {
              final image = await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
              try {
                final png =
                    await image.toByteData(format: ui.ImageByteFormat.png);
                await Directory(directory).create(recursive: true);
                await File('$directory/detail-$label.png')
                    .writeAsBytes(png!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        });
      }
    }
  }
}
