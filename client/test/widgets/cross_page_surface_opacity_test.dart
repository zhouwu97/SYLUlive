import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/emoji/application/emoji_recent_manager.dart';
import 'package:shenliyuan/models/course_term.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/services/emoji_favorite_service.dart';
import 'package:shenliyuan/widgets/about_app_sheet.dart';
import 'package:shenliyuan/widgets/ai/ai_mode_switch.dart';
import 'package:shenliyuan/widgets/course/course_import_sheet.dart';
import 'package:shenliyuan/widgets/course/course_semester_start_sheet.dart';
import 'package:shenliyuan/widgets/course/course_semester_start_picker.dart';
import 'package:shenliyuan/widgets/course/course_term_switch_sheet.dart';
import 'package:shenliyuan/widgets/emoji/app_emoji_panel.dart';
import 'package:shenliyuan/widgets/exam_papers/exam_paper_toolbar.dart';
import 'package:shenliyuan/widgets/glass_container.dart';

import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

const _backdrop = Color(0xFF245C90);
const _output = String.fromEnvironment('CROSS_PAGE_SURFACE_QA_OUTPUT');
const _term = CourseTerm(
    id: '2026-3', year: '2026', semester: 3, title: '2026—2027 学年第一学期');

Finder _boxAround(Finder child) => find
    .ancestor(
        of: child,
        matching: find.byWidgetPredicate((widget) =>
            widget.runtimeType == Container &&
            (widget as Container).decoration is BoxDecoration))
    .first;

Finder _target(String scene) => _boxAround(switch (scene) {
      'about' => find.text('当前版本'),
      'term' || 'import' => find.byType(ListTile).at(1),
      'semester' || 'picker' => find.text('尚未选择'),
      'emoji' => find.byTooltip('表情管理'),
      'exam' => find.byType(DropdownButton<String>).at(1),
      _ => find.text('校园 Agent'),
    });

Future<List<Color>> _pixels(WidgetTester tester, GlobalKey capture,
    List<Offset> points, String name) async {
  return (await tester.runAsync(() async {
    final image = await (capture.currentContext!.findRenderObject()!
            as RenderRepaintBoundary)
        .toImage(pixelRatio: 1);
    try {
      if (_output.isNotEmpty) {
        await Directory(_output).create(recursive: true);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$_output/$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
      }
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return points.map((point) {
        final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
        return Color.fromARGB(
            bytes.getUint8(offset + 3),
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2));
      }).toList();
    } finally {
      image.dispose();
    }
  }))!;
}

double _difference(Color a, Color b) => [
      (a.r - b.r).abs(),
      (a.g - b.g).abs(),
      (a.b - b.b).abs()
    ].reduce((a, b) => a > b ? a : b);

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await (FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
        .load();
  });
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
        appName: '沈理校园',
        packageName: 'fixture.local',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '');
  });

  for (final dark in [false, true]) {
    for (final scene in [
      'about',
      'term',
      'import',
      'semester',
      'picker',
      'emoji',
      'exam',
      'ai',
    ]) {
      testWidgets('内层沿用卡片不透明度 $scene dark=$dark', (tester) async {
        await setGoldenViewport(tester, GoldenViewports.phone390x844);
        final appearance = ThemeProvider(loadOnStart: false);
        addTearDown(appearance.dispose);
        await appearance.setBackgroundImage('morenbeijing.jpeg');
        final search = TextEditingController();
        addTearDown(search.dispose);
        final edu = EduProvider(Dio());
        addTearDown(edu.dispose);
        final prefs = MemoryPreferencesStore();
        final favorites =
            EmojiFavoriteService(preferencesLoader: () async => prefs);
        final recent = EmojiRecentManager(preferencesLoader: () async => prefs);
        final child = switch (scene) {
          'about' => const AboutAppSheet(),
          'term' => const CourseTermSwitchSheet(
              currentTerm: _term, enrollmentYear: 2025),
          'import' => CourseImportSheet(
              eduProvider: edu, initialYear: '2026', initialSemester: 3),
          'semester' => const CourseSemesterStartSheet(term: _term),
          'picker' => Builder(
              builder: (context) => TextButton(
                  onPressed: () =>
                      CourseSemesterStartPicker.show(context, term: _term),
                  child: const Text('设置开学日期'))),
          'emoji' => SizedBox(
              height: 320,
              child: AppEmojiPanel(
                  favoriteService: favorites,
                  recentManager: recent,
                  onEmojiSelected: (_) {},
                  onBackspace: () {})),
          'exam' => Column(mainAxisSize: MainAxisSize.min, children: [
              ExamPaperToolbar(
                  searchController: search,
                  onSearchChanged: (_) {},
                  academicYear: '',
                  semester: '',
                  examType: '',
                  sort: 'latest',
                  academicYears: const ['2026-2027'],
                  onAcademicYearChanged: (_) {},
                  onSemesterChanged: (_) {},
                  onExamTypeChanged: (_) {},
                  onSortChanged: (_) {},
                  total: 0,
                  activeFilterCount: 0,
                  onClearSearch: () {},
                  onClearFilters: () {})
            ]),
          _ => AiModeSwitch(isPersonalMode: false, onModeChanged: (_) {}),
        };
        final capture = GlobalKey();
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: appearance,
          child: RepaintBoundary(
            key: capture,
            child: GoldenTestApp(
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              textScaler:
                  dark ? const TextScaler.linear(1.3) : TextScaler.noScaling,
              home: Scaffold(
                  backgroundColor: _backdrop, body: Center(child: child)),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        if (scene == 'picker') {
          await tester.tap(find.text('设置开学日期'));
          await tester.pumpAndSettle();
        }
        final target = _target(scene);
        final rect = tester.getRect(target);
        final point = switch (scene) {
          'semester' || 'picker' => Offset(rect.left + 8, rect.top + 8),
          'emoji' => Offset(rect.left + 2, rect.center.dy),
          'exam' => Offset(rect.left + 1, rect.center.dy),
          _ => Offset(rect.left + 8, rect.center.dy),
        };
        final reference = switch (scene) {
          'semester' || 'picker' || 'emoji' => Offset(point.dx, rect.top - 5),
          'exam' => Offset(
              tester.getRect(find.byType(GlassContainer)).left + 4, point.dy),
          _ => Offset(rect.left - 4, point.dy),
        };
        Color? previous;
        for (final alpha in [0.0, 1.0]) {
          await appearance.setComponentOpacityLevel(alpha);
          await tester.pumpAndSettle();
          final pixels = await _pixels(tester, capture, [point, reference],
              '$scene-${dark ? 'dark' : 'light'}-$alpha');
          if (scene != 'ai') {
            expect(
                _difference(pixels[0], pixels[1]), lessThanOrEqualTo(4 / 255),
                reason: '内层空白区域应与周围同属一块卡片底面');
          }
          if (previous != null) {
            expect(_difference(pixels[0], previous), greaterThan(8 / 255),
                reason: '调节不透明度时不能留下固定实色块');
          }
          previous = pixels[0];
        }
        for (final glass in [true, false]) {
          await appearance.setFrostedGlass(glass);
          await tester.pumpAndSettle();
          expect(tester.getRect(target), rect);
        }
        if (scene == 'term' || scene == 'import') {
          final tile = find.byType(ListTile).at(1);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(
              find.descendant(
                  of: tile, matching: find.byIcon(Icons.check_circle_rounded)),
              findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
