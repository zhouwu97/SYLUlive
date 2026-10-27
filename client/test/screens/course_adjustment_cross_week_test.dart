import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/schedule/course.dart';
import 'package:shenliyuan/models/schedule/course_source.dart';
import 'package:shenliyuan/models/schedule/meeting.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/screens/schedule/reschedule/course_adjustment_sheet.dart';
import 'package:shenliyuan/screens/schedule/reschedule/select_weeks_sheet.dart';
import '../helpers/golden_test_app.dart';
import '../helpers/golden_viewport.dart';
import '../helpers/load_test_fonts.dart';

class _ControlledPreferences extends MemoryPreferencesStore {
  Completer<bool>? pending;
  int writes = 0;
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    final gate = pending;
    if (gate != null && !await gate.future) return false;
    return super.setString(key, value);
  }
}

const _course = CourseBlock(
    id: 1,
    courseCode: 'C1',
    name: '网络安全技术',
    color: '#147C72',
    weekday: 1,
    startSection: 5,
    endSection: 6,
    weeks: [8, 9, 10],
    courseKey: 'course',
    meetingKey: 'meeting');

Future<void> _capture(WidgetTester tester, String name) async {
  const output = String.fromEnvironment('SCHEDULE_QA_OUTPUT');
  if (output.isEmpty) return;
  final boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('qa')));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(output).create(recursive: true);
    await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<CourseScheduleProvider> _open(WidgetTester tester,
    {ThemeMode mode = ThemeMode.light, double scale = 1}) async {
  await setGoldenViewport(tester, GoldenViewports.phone360x800);
  final provider = CourseScheduleProvider();
  addTearDown(provider.dispose);
  provider.setBaseScheduleForTesting([
    Course(
      courseKey: 'course',
      semesterId: provider.currentTerm.id,
      source: CourseSource.edu,
      name: _course.name,
      meetings: const [
        Meeting(
          meetingKey: 'meeting',
          weekday: 1,
          startSection: 5,
          endSection: 6,
          weeks: {8, 9, 10},
        )
      ],
    )
  ]);
  await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('qa'),
      child: GoldenTestApp(
        themeMode: mode,
        textScaler: TextScaler.linear(scale),
        home: Scaffold(
            body: Builder(
                builder: (context) => Center(
                    child: FilledButton(
                        onPressed: () => CourseAdjustmentSheet.show(context,
                            course: _course,
                            provider: provider,
                            currentAcademicWeek: 9),
                        child: const Text('调整'))))),
      )));
  await tester.tap(find.text('调整'));
  await tester.pumpAndSettle();
  return provider;
}

Future<void> _toConfirmation(WidgetTester tester, {String? captureName}) async {
  await tester.tap(find.text('仅本周 (第9周)'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('下一步：选择目标时间'));
  await tester.tap(find.text('下一步：选择目标时间'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('reschedule-target-week')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('第 8 周').last);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('下一步：冲突检查与确认'));
  await tester.pumpAndSettle();
  if (captureName != null) await _capture(tester, '$captureName-target');
  await tester.tap(find.text('下一步：冲突检查与确认'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() => AppPreferencesStore.setCustomInstance(MemoryPreferencesStore()));
  tearDown(() => AppPreferencesStore.setCustomInstance(null));

  for (final profile in [
    ('light', ThemeMode.light, 1.0),
    ('dark', ThemeMode.dark, 1.0),
    ('large', ThemeMode.light, 1.3),
    ('stress', ThemeMode.dark, 1.5)
  ]) {
    testWidgets('跨周调课选择、合并与保存 ${profile.$1}', (tester) async {
      final provider = await _open(tester, mode: profile.$2, scale: profile.$3);
      await _capture(tester, '${profile.$1}-source');
      await _toConfirmation(tester, captureName: profile.$1);
      expect(find.text('第9周'), findsOneWidget);
      expect(find.text('第8周'), findsOneWidget);
      expect(find.text('目标时间已有同一课程'), findsOneWidget);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(find.text('未发现课程冲突'), findsOneWidget);
      await tester.ensureVisible(find.text('合并并确认修改'));
      await _capture(tester, '${profile.$1}-confirm');
      await tester.tap(find.text('合并并确认修改'));
      await tester.pumpAndSettle();
      expect(find.byType(CourseAdjustmentSheet), findsNothing);
      expect(provider.overrides.single.weekOffset, -1);
      expect(provider.overrides.single.affectedWeeks, {9});
      expect(provider.courses.where((c) => c.weeks.contains(8)), hasLength(1));
      expect(provider.courses.any((c) => c.weeks.contains(9)), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('保存中禁止重复提交，失败保持草稿并可重试', (tester) async {
    final preferences = _ControlledPreferences()..pending = Completer<bool>();
    AppPreferencesStore.setCustomInstance(preferences);
    final provider = await _open(tester);
    await _toConfirmation(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('合并并确认修改'));
    await tester.tap(find.text('合并并确认修改'));
    await tester.pump();
    expect(find.text('正在保存…'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '正在保存…'))
            .onPressed,
        isNull);
    await _capture(tester, 'saving');
    expect(preferences.writes, 1);
    preferences.pending!.complete(false);
    await tester.pumpAndSettle();
    expect(find.textContaining('保存调整失败，请重试'), findsOneWidget);
    expect(find.byType(CourseAdjustmentSheet), findsOneWidget);
    expect(provider.overrides, isEmpty);
    await tester.ensureVisible(find.text('合并并确认修改'));
    await _capture(tester, 'save-error');
    preferences.pending = null;
    await tester.tap(find.text('合并并确认修改'));
    await tester.pumpAndSettle();
    expect(provider.overrides, hasLength(1));
    expect(find.byType(CourseAdjustmentSheet), findsNothing);
  });

  testWidgets('返回上一步保留原周次和目标周次草稿', (tester) async {
    await _open(tester);
    await _toConfirmation(tester);
    await tester.tap(find.byTooltip('返回修改'));
    await tester.pumpAndSettle();
    expect(find.text('第 8 周'), findsOneWidget);
    await tester.tap(find.byTooltip('返回上一步'));
    await tester.pumpAndSettle();
    expect(find.text('实际影响周次'), findsOneWidget);
    expect(find.text('第 9 周（共 1 周）'), findsOneWidget);
    await tester.tap(find.text('下一步：选择目标时间'));
    await tester.pumpAndSettle();
    expect(find.text('第 8 周'), findsOneWidget);
  });

  testWidgets('保存期间切换账号，旧操作不覆盖新会话内存', (tester) async {
    final preferences = _ControlledPreferences()..pending = Completer<bool>();
    AppPreferencesStore.setCustomInstance(preferences);
    final provider = await _open(tester);
    await _toConfirmation(tester);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('合并并确认修改'));
    await tester.tap(find.text('合并并确认修改'));
    await tester.pump();
    provider.clearAllUserState();
    preferences.pending!.complete(true);
    await tester.pumpAndSettle();
    expect(provider.overrides, isEmpty);
    expect(provider.courses, isEmpty);
    expect(find.textContaining('账号或学期已切换'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺少原始快照时给出恢复提示', (tester) async {
    final provider = CourseScheduleProvider();
    addTearDown(provider.dispose);
    await tester.pumpWidget(GoldenTestApp(
        home: Scaffold(
            body: CourseAdjustmentSheet(
      course: _course,
      provider: provider,
      currentAcademicWeek: 9,
    ))));
    expect(find.textContaining('无法定位该课程的教务原始安排'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('下一步：选择目标时间'), findsNothing);
  });

  testWidgets('原周次没有课程时禁用下一步', (tester) async {
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(GoldenTestApp(
        home: Scaffold(
            body: SelectWeeksSheet(
      course: _course,
      currentAcademicWeek: 7,
      totalTeachingWeeks: 20,
      onNext: (_) => fail('空周次不能进入下一步'),
    ))));
    await tester.tap(find.text('仅本周 (第7周)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('实际影响 0 周'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.widgetWithText(FilledButton, '下一步：选择目标时间'))
            .onPressed,
        isNull);
  });
}
