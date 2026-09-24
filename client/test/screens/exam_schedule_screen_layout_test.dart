import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/exam_schedule.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/services/exam_schedule_repository.dart';
import 'package:shenliyuan/screens/exam_schedule_screen.dart';

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
  });

  testWidgets('窄屏考试页工具栏不会发生横向溢出', (tester) async {
    for (final width in <double>[432, 360]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;

      await tester.pumpWidget(
        const MaterialApp(home: ExamScheduleScreen()),
      );
      await tester.pump();

      final titleRect = tester.getRect(find.byType(DropdownButton<String>));
      final actionRects = [
        tester.getRect(find.byTooltip('桌面小组件')),
        tester.getRect(find.byTooltip('导入存档')),
        tester.getRect(find.byTooltip('导出存档')),
        tester.getRect(find.byTooltip('添加考试')),
      ];

      expect(titleRect.right, lessThanOrEqualTo(actionRects.first.left));
      expect(actionRects.last.right, lessThanOrEqualTo(width));
      expect(tester.takeException(), isNull);
    }

    addTearDown(tester.view.reset);
  });

  testWidgets('考试卡片提供明确的删除入口并持久化删除结果', (tester) async {
    final exam = ExamModel(
      name: '数据结构',
      startTime: DateTime(2026, 9, 24, 19, 29),
      endTime: DateTime(2026, 9, 24, 21, 29),
      location: '11',
      semester: '2026-2027-01',
    );
    AppPreferencesStore.setMockInitialValues(<String, Object>{
      ExamScheduleRepository.localExamsKey: jsonEncode([exam.toJson()]),
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: const MaterialApp(home: ExamScheduleScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('删除考试'), findsOneWidget);
    await tester.tap(find.byTooltip('删除考试'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除'), findsOneWidget);

    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    expect(find.text('数据结构'), findsNothing);
    expect(await ExamScheduleRepository().load(), isEmpty);
  });
}
