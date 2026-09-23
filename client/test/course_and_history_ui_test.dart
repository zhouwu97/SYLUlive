import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/browsing_history_item.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_evaluation_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/repositories/browsing_history_repository.dart';
import 'package:shenliyuan/screens/browsing_history_screen.dart';
import 'package:shenliyuan/screens/schedule/course_detail_sheet.dart';
import 'package:shenliyuan/screens/schedule/reschedule/confirm_change_sheet.dart';
import 'package:shenliyuan/services/schedule/schedule_conflict_service.dart';
import 'package:shenliyuan/models/schedule/course.dart';
import 'package:shenliyuan/models/schedule/meeting.dart';
import 'package:shenliyuan/models/schedule/course_source.dart';
import 'package:shenliyuan/models/schedule/schedule_override.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/screens/schedule/reschedule/course_adjustment_sheet.dart';

class _TestAuthProvider extends AuthProvider {
  _TestAuthProvider() : super(Dio(), loadStoredAuth: false);

  @override
  User? get user => User(
        id: 1,
        studentId: '20260001',
        nickname: '测试学生',
        createdAt: DateTime(2026),
      );
}

class _TestCourseEvaluationProvider extends CourseEvaluationProvider {
  _TestCourseEvaluationProvider() : super(null);
}

class _RecordingCourseScheduleProvider extends CourseScheduleProvider {
  int rescheduleSaveCount = 0;
  String? lastSavedOverrideId;
  int? lastSavedStartSection;
  String? lastSavedRoom;

  @override
  Future<ScheduleOverride> createRescheduleOverride({
    required String courseKey,
    required String meetingKey,
    required Set<int> affectedWeeks,
    required int toWeekday,
    required int toStartSection,
    required int toEndSection,
    String? toRoom,
    required String sourceSnapshotHash,
    int? fromWeekday,
    int? fromStartSection,
    int? fromEndSection,
    String? fromRoom,
    bool allowConflict = false,
    String? overrideId,
  }) async {
    rescheduleSaveCount++;
    lastSavedOverrideId = overrideId;
    lastSavedStartSection = toStartSection;
    lastSavedRoom = toRoom;
    final now = DateTime(2026);
    return ScheduleOverride(
      id: overrideId ?? 'test_override',
      semesterId: currentTerm.id,
      courseKey: courseKey,
      meetingKey: meetingKey,
      type: ScheduleOverrideType.reschedule,
      affectedWeeks: affectedWeeks,
      toWeekday: toWeekday,
      toStartSection: toStartSection,
      toEndSection: toEndSection,
      toRoom: toRoom,
      sourceSnapshotHash: sourceSnapshotHash,
      fromWeekday: fromWeekday,
      fromStartSection: fromStartSection,
      fromEndSection: fromEndSection,
      fromRoom: fromRoom,
      createdAt: now,
      updatedAt: now,
    );
  }
}

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  group('CourseDetailSheet 组件交互测试 (Section 16 & 17)', () {
    testWidgets('正常教务课程展示完整字段、来源及统一调整入口', (tester) async {
      const course = CourseBlock(
        id: 101,
        courseCode: '080123',
        name: '数字图像处理',
        teacher: '王辉宇',
        location: 'XX-430',
        color: '#3B82F6',
        weekday: 1,
        startSection: 3,
        endSection: 4,
        weeks: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
        teachingClassId: 'TC20260127',
        courseKey: 'edu:2026_1:080123:TC20260127',
        meetingKey: 'm_1_3_4',
        source: 'edu',
      );

      final provider = CourseScheduleProvider()
        ..setBaseScheduleForTesting([
          Course(
            courseKey: 'edu:2026_1:080123:TC20260127',
            semesterId: '2026_1',
            source: CourseSource.edu,
            name: '数字图像处理',
            courseCode: '080123',
            teachingClassId: 'TC20260127',
            meetings: const [
              Meeting(
                meetingKey: 'm_1_3_4',
                weekday: 1,
                startSection: 3,
                endSection: 4,
                weeks: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13},
                room: 'XX-430',
                teacher: '王辉宇',
              ),
            ],
          ),
        ]);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<CourseScheduleProvider>.value(
                value: provider),
            ChangeNotifierProvider<AuthProvider>(
                create: (_) => _TestAuthProvider()),
            ChangeNotifierProvider<CourseEvaluationProvider>(
              create: (_) => _TestCourseEvaluationProvider(),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: CourseDetailSheet(
                course: course,
                currentAcademicWeek: 5,
              ),
            ),
          ),
        ),
      );

      // 验证课程名称与教务来源
      expect(find.text('数字图像处理'), findsOneWidget);
      expect(find.text('教务课表'), findsOneWidget);

      // 验证详细字段
      expect(find.text('王辉宇'), findsOneWidget);
      expect(find.text('XX-430'), findsOneWidget);
      expect(find.text('周一 第3-4节'), findsOneWidget);
      expect(find.text('第1-13周'), findsOneWidget);
      expect(find.text('080123'), findsOneWidget);
      expect(find.text('TC20260127'), findsOneWidget);

      // 验证操作按钮并测试进入调课流程
      expect(find.text('调整课程安排'), findsOneWidget);
      await tester.tap(find.text('调整课程安排'));
      await tester.pumpAndSettle();
      expect(find.text('调整课程安排 (1/3)'), findsOneWidget);
    });

    testWidgets('本地调整课程展示「教务课表 + 本地调整」以及「继续调整」「恢复原安排」', (tester) async {
      const course = CourseBlock(
        id: 101,
        courseCode: '080123',
        name: '数字图像处理',
        teacher: '王辉宇',
        location: 'XX-430',
        color: '#3B82F6',
        weekday: 3,
        startSection: 1,
        endSection: 2,
        weeks: [5, 6, 7, 8],
        courseKey: 'edu:2026_1:080123',
        meetingKey: 'm_1_3_4',
        isOverridden: true,
        overrideId: 'ov_123',
        source: 'edu',
      );

      final provider = CourseScheduleProvider()
        ..setBaseScheduleForTesting([
          Course(
            courseKey: 'edu:2026_1:080123',
            semesterId: '2026_1',
            source: CourseSource.edu,
            name: '数字图像处理',
            courseCode: '080123',
            meetings: const [
              Meeting(
                meetingKey: 'm_1_3_4',
                weekday: 1,
                startSection: 3,
                endSection: 4,
                weeks: {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13},
                room: 'XX-430',
                teacher: '王辉宇',
              ),
            ],
          ),
        ]);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<CourseScheduleProvider>.value(
                value: provider),
            ChangeNotifierProvider<AuthProvider>(
                create: (_) => _TestAuthProvider()),
            ChangeNotifierProvider<CourseEvaluationProvider>(
              create: (_) => _TestCourseEvaluationProvider(),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: CourseDetailSheet(
                course: course,
                currentAcademicWeek: 6,
              ),
            ),
          ),
        ),
      );

      expect(find.text('教务课表 + 本地调整'), findsOneWidget);
      expect(find.text('继续调整'), findsOneWidget);
      expect(find.text('恢复原安排'), findsOneWidget);

      await tester.tap(find.text('继续调整'));
      await tester.pumpAndSettle();
      expect(find.text('调整课程安排 (1/3)'), findsOneWidget);
    });
  });

  group('ConfirmChangeSheet 确认与冲突提示测试 (Section 20)', () {
    testWidgets('无冲突时展示「未发现课程冲突」和「确认修改」', (tester) async {
      const course = CourseBlock(
        id: 101,
        courseCode: '080123',
        name: '数字图像处理',
        color: '#3B82F6',
        weekday: 1,
        startSection: 3,
        endSection: 4,
        weeks: [1, 2, 3, 4, 5, 6, 7, 8],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfirmChangeSheet(
              course: course,
              affectedWeeks: const {5, 6, 7, 8},
              toWeekday: 3,
              toStartSection: 1,
              toEndSection: 2,
              conflictResult: const ScheduleConflictCheckResult(
                hasConflict: false,
                conflicts: [],
              ),
              onConfirm: () {},
              onBackToEdit: () {},
            ),
          ),
        ),
      );

      expect(find.text('未发现课程冲突'), findsOneWidget);
      expect(find.text('确认修改'), findsOneWidget);
      expect(find.text('返回修改'), findsNothing);
    });

    testWidgets('发现冲突时展示「发现时间冲突」及「返回修改」「保留冲突并保存」', (tester) async {
      const course = CourseBlock(
        id: 101,
        courseCode: '080123',
        name: '数字图像处理',
        color: '#3B82F6',
        weekday: 1,
        startSection: 3,
        endSection: 4,
        weeks: [1, 2, 3, 4, 5, 6, 7, 8],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfirmChangeSheet(
              course: course,
              affectedWeeks: const {6},
              toWeekday: 3,
              toStartSection: 1,
              toEndSection: 2,
              conflictResult: const ScheduleConflictCheckResult(
                hasConflict: true,
                conflicts: [
                  ScheduleConflictInfo(
                    existingCourseName: '高频电子线路',
                    conflictingWeeks: {6},
                    weekday: 3,
                    startSection: 1,
                    endSection: 2,
                  ),
                ],
              ),
              onConfirm: () {},
              onBackToEdit: () {},
            ),
          ),
        ),
      );

      expect(find.text('发现时间冲突'), findsOneWidget);
      expect(find.textContaining('已有课程：高频电子线路'), findsOneWidget);
      expect(find.text('返回修改'), findsOneWidget);
      expect(find.text('保留冲突并保存'), findsOneWidget);
    });
  });

  testWidgets('已有调课换回原时间时仍保存并保留已调整教室', (tester) async {
    final provider = _RecordingCourseScheduleProvider()
      ..setBaseScheduleForTesting([
        const Course(
          courseKey: 'edu:2026_1:XX-228',
          semesterId: '2026_1',
          source: CourseSource.edu,
          name: '数字信号处理',
          meetings: [
            Meeting(
              meetingKey: 'meeting-xx-228',
              weekday: 5,
              startSection: 5,
              endSection: 6,
              weeks: {1, 2, 3, 4, 7, 8, 9, 10, 11, 12},
              room: 'XX-228',
            ),
          ],
        ),
      ]);
    addTearDown(provider.dispose);
    final existingOverride = ScheduleOverride(
      id: 'override-dsp',
      semesterId: '2026_1',
      courseKey: 'edu:2026_1:XX-228',
      meetingKey: 'meeting-xx-228',
      type: ScheduleOverrideType.reschedule,
      affectedWeeks: {1, 2, 3, 4, 7, 8, 9, 10, 11, 12},
      toWeekday: 5,
      toStartSection: 7,
      toEndSection: 8,
      toRoom: 'XX-999',
      sourceSnapshotHash: 'snapshot',
      fromWeekday: 5,
      fromStartSection: 5,
      fromEndSection: 6,
      fromRoom: 'XX-228',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    const displayedCourse = CourseBlock(
      id: 228,
      courseCode: 'XX-228',
      name: '数字信号处理',
      location: 'XX-999',
      color: '#3B82F6',
      weekday: 5,
      startSection: 7,
      endSection: 8,
      weeks: [1, 2, 3, 4, 7, 8, 9, 10, 11, 12],
      courseKey: 'edu:2026_1:XX-228',
      meetingKey: 'meeting-xx-228',
      source: 'edu',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            key: const Key('open-adjustment'),
            onPressed: () => CourseAdjustmentSheet.show(
              context,
              course: displayedCourse,
              provider: provider,
              currentAcademicWeek: 5,
              existingOverride: existingOverride,
            ),
            child: const Text('打开调课'),
          ),
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('open-adjustment')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步：选择目标时间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5-6节'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步：冲突检查与确认'));
    await tester.pumpAndSettle();

    expect(find.text('未发现课程冲突'), findsOneWidget);
    expect(find.textContaining('7-8节'), findsOneWidget);
    expect(find.textContaining('5-6节'), findsOneWidget);
    await tester.ensureVisible(find.text('确认修改'));
    await tester.tap(find.text('确认修改'));
    await tester.pumpAndSettle();

    expect(provider.rescheduleSaveCount, 1);
    expect(provider.lastSavedOverrideId, existingOverride.id);
    expect(provider.lastSavedStartSection, 5);
    expect(provider.lastSavedRoom, 'XX-999');
    expect(find.text('未检测到任何修改'), findsNothing);
  });

  group('BrowsingHistoryScreen 浏览记录测试 (Section 30 & 43)', () {
    testWidgets('浏览记录界面正确渲染标签、记录与清空按钮', (tester) async {
      final repo = BrowsingHistoryRepository();
      await repo.recordVisit(
        userId: '1',
        targetId: '99',
        type: BrowsingHistoryType.campusNews,
        title: '2026-2027学年开学通知',
        author: '教务处',
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => _TestAuthProvider(),
          child: const MaterialApp(
            home: BrowsingHistoryScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('浏览记录'), findsOneWidget);
      expect(find.text('全部'), findsOneWidget);
      expect(find.text('校园资讯'), findsWidgets);
      expect(find.text('帖子'), findsOneWidget);
      expect(find.text('2026-2027学年开学通知'), findsOneWidget);
      expect(find.byIcon(Icons.delete_sweep_outlined), findsOneWidget);
    });
  });

  group('ThemeProvider 跟随系统夜间模式测试 (Section 36 & 44)', () {
    test('默认启用跟随系统，ThemeMode 映射为 ThemeMode.system', () async {
      final themeProvider = ThemeProvider(loadOnStart: false);
      await themeProvider.loadThemeForTesting();

      expect(themeProvider.followSystem, isTrue);
      expect(themeProvider.themeMode, ThemeMode.system);

      // 关闭跟随系统并设为深色
      await themeProvider.setFollowSystem(false);
      await themeProvider.setDarkMode(true);
      expect(themeProvider.followSystem, isFalse);
      expect(themeProvider.themeMode, ThemeMode.dark);

      // 设为浅色
      await themeProvider.setDarkMode(false);
      expect(themeProvider.themeMode, ThemeMode.light);

      // 再次启用跟随系统
      await themeProvider.setFollowSystem(true);
      expect(themeProvider.themeMode, ThemeMode.system);
    });
  });
}
