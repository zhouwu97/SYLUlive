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

  testWidgets('取消删除不改变卡片与存档', (tester) async {
    final exam = ExamModel(
      name: '高等数学',
      startTime: DateTime(2026, 9, 25, 8, 0),
      endTime: DateTime(2026, 9, 25, 10, 0),
      location: '教学楼A',
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

    await tester.tap(find.byTooltip('删除考试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsOneWidget);
    expect((await ExamScheduleRepository().load()).length, 1);
  });

  testWidgets('保存失败时卡片恢复且存档保留', (tester) async {
    final exam = ExamModel(
      name: '大学英语',
      startTime: DateTime(2026, 9, 26, 14, 0),
      endTime: DateTime(2026, 9, 26, 16, 0),
      location: '外语楼',
      semester: '2026-2027-01',
    );
    AppPreferencesStore.setMockInitialValues(<String, Object>{
      ExamScheduleRepository.localExamsKey: jsonEncode([exam.toJson()]),
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<ThemeProvider>(
        create: (_) => ThemeProvider(loadOnStart: false),
        child: MaterialApp(
          home: ExamScheduleScreen(
            examRepository: _FailingExamRepository(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除考试'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    // 保存失败后卡片必须回到列表，而不是停留在一个“看起来删掉了”的界面。
    expect(find.text('大学英语'), findsOneWidget);
  });

  testWidgets('无障碍树可以找到删除考试入口', (tester) async {
    final exam = ExamModel(
      name: '线性代数',
      startTime: DateTime(2026, 9, 27, 10, 0),
      endTime: DateTime(2026, 9, 27, 12, 0),
      location: '理学院',
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

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('删除考试'),
      findsOneWidget,
    );
    semantics.dispose();
  });
}

/// 保存永远失败的仓储桩：用于验证删除失败路径不破坏界面与数据一致性。
class _FailingExamRepository implements ExamScheduleRepository {
  @override
  Future<void> clear() async {}

  @override
  Future<List<ExamModel>> load() async {
    final exam = ExamModel(
      name: '大学英语',
      startTime: DateTime(2026, 9, 26, 14, 0),
      endTime: DateTime(2026, 9, 26, 16, 0),
      location: '外语楼',
      semester: '2026-2027-01',
    );
    return [exam];
  }

  @override
  Future<void> save(List<ExamModel> exams) async {
    throw Exception('写入失败');
  }
}
