import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_subject_provider.dart';
import 'package:shenliyuan/providers/major_provider.dart';
import 'package:shenliyuan/providers/teacher_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/campus_ranking_screen.dart';
import 'package:shenliyuan/widgets/app_card.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  for (final dark in [false, true]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('榜单提示、错误、空态与搜索无结果有底面 dark=$dark scale=$scale',
          (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        AppPreferencesStore.setMockInitialValues({});
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        await appearance.setComponentOpacity(.75);
        var fail = true;
        var subjects = <Map<String, dynamic>>[];
        final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid'));
        addTearDown(() => dio.close(force: true));
        dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
          if (o.path == '/course-subjects' && fail) {
            h.reject(DioException(
                requestOptions: o, type: DioExceptionType.connectionError));
          } else {
            h.resolve(Response(
                requestOptions: o,
                statusCode: 200,
                data: o.path == '/course-subjects' ? subjects : []));
          }
        }));
        final subjectProvider = CourseSubjectProvider(dio);
        await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: appearance),
            ChangeNotifierProvider(create: (_) => subjectProvider),
            ChangeNotifierProvider(create: (_) => MajorProvider(dio)),
            ChangeNotifierProvider(create: (_) => TeacherProvider(dio)),
            ChangeNotifierProvider(
                create: (_) => AuthProvider(dio, loadStoredAuth: false)),
          ],
          child: GoldenTestApp(
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            textScaler: TextScaler.linear(scale),
            home: const CampusRankingScreen(),
          ),
        ));
        await tester.pumpAndSettle();

        Future<void> checkSurface(Finder text) async {
          expect(text, findsOneWidget);
          expect(find.ancestor(of: text, matching: find.byType(AppCardSurface)),
              findsWidgets);
          final rect = tester.getRect(text);
          for (final glass in [true, false]) {
            await appearance.setFrostedGlass(glass);
            await tester.pumpAndSettle();
            expect(tester.getRect(text), rect);
            expect(tester.takeException(), isNull);
          }
        }

        await checkSurface(find.textContaining('学科榜按课程聚合'));
        final disclaimer = tester.widget<AppCardSurface>(find
            .ancestor(
                of: find.textContaining('学科榜按课程聚合'),
                matching: find.byType(AppCardSurface))
            .first);
        expect(disclaimer.margin, const EdgeInsets.fromLTRB(16, 6, 16, 0));
        expect(disclaimer.padding,
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10));
        await checkSurface(find.text(subjectProvider.error!));
        fail = false;
        await tester.tap(find.text('重试'));
        await tester.pumpAndSettle();
        await checkSurface(find.text('暂无学科数据'));
        subjects = [
          {'id': 1, 'name': '数据结构'}
        ];
        unawaited(subjectProvider.loadSubjects(force: true));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '不存在的学科');
        await tester.pumpAndSettle();
        await checkSurface(find.text('未找到相关学科'));
        await tester.tap(find.text('专业榜'));
        await tester.pumpAndSettle();
        await checkSurface(find.text('暂无专业'));
      });
    }
  }
}
