import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/widgets/course/course_preview_sheet.dart';

void main() {
  Future<void> pumpPreview(
    WidgetTester tester, {
    required List<Map<String, dynamic>> courses,
    ThemeMode themeMode = ThemeMode.light,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    final provider = EduProvider(Dio());
    addTearDown(provider.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: themeMode,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: CoursePreviewSheet(
            courses: courses,
            year: '2026',
            semester: 3,
            eduProvider: provider,
          ),
        ),
      ),
    );
  }

  testWidgets('本机课表规范字段保留真实星期和节次', (tester) async {
    await pumpPreview(
      tester,
      courses: const [
        {
          'name': '材料科学基础A',
          'teacher': '高志玉',
          'location': 'A-310',
          'weekday': 1,
          'start_section': 1,
          'end_section': 2,
          'weeks': [1, 2, 3],
        },
        {
          'name': '大学物理',
          'weekday': 4,
          'start_section': 3,
          'end_section': 4,
          'weeks': [1, 2, 3],
        },
        {
          'name': '工程制图',
          'weekday': 7,
          'start_section': 7,
          'end_section': 8,
          'weeks': [1, 2, 3],
        },
      ],
    );

    expect(find.text('共 3 门课 · 3 个上课日'), findsOneWidget);
    expect(find.text('周一'), findsOneWidget);
    expect(find.text('周四'), findsOneWidget);
    expect(find.text('周日'), findsOneWidget);
    expect(find.text('第1-2节'), findsOneWidget);
    expect(find.text('第3-4节'), findsOneWidget);
    expect(find.text('第7-8节'), findsOneWidget);
  });

  testWidgets('缺失定位字段不再伪装成周一或第 0 节', (tester) async {
    await pumpPreview(
      tester,
      courses: const [
        {
          'name': '定位缺失课程',
          'weekday': 0,
          'start_section': 0,
          'end_section': 0,
        },
      ],
    );

    expect(find.text('共 1 门课 · 0 个上课日 · 1 门课程缺少有效排课坐标'), findsOneWidget);
    expect(find.text('星期未知'), findsOneWidget);
    expect(find.text('节次未知'), findsOneWidget);
    expect(find.text('周一'), findsNothing);
    expect(find.text('第0-0节'), findsNothing);
  });

  testWidgets('研究生预览显示学校原节次标签', (tester) async {
    await pumpPreview(
      tester,
      courses: const [
        {
          'name': '研究生专题课',
          'weekday': 1,
          'start_section': 3,
          'end_section': 3,
          'period_order': 2,
          'period_label': '上午3',
          'weeks': [1, 2, 3],
        },
      ],
    );

    expect(find.text('上午3'), findsOneWidget);
    expect(find.text('第3-3节'), findsNothing);
  });

  testWidgets('深色和大字号下定位诊断文案可完整显示', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpPreview(
      tester,
      themeMode: ThemeMode.dark,
      textScaler: const TextScaler.linear(1.3),
      courses: const [
        {
          'name': '定位缺失课程',
          'weekday': 0,
          'start_section': 0,
          'end_section': 0,
        },
      ],
    );

    expect(
      find.text('共 1 门课 · 0 个上课日 · 1 门课程缺少有效排课坐标'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
