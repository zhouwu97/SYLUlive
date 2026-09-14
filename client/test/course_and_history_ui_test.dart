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
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

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

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  group('CourseDetailSheet 组件交互测试 (Section 16 & 17)', () {
    testWidgets('正常教务课程展示完整字段、来源及更换时间/修改教室按钮', (tester) async {
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

      final provider = CourseScheduleProvider();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<CourseScheduleProvider>.value(value: provider),
            ChangeNotifierProvider<AuthProvider>(create: (_) => _TestAuthProvider()),
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

      // 验证操作按钮
      expect(find.text('更换时间'), findsOneWidget);
      expect(find.text('修改教室'), findsOneWidget);
    });

    testWidgets('本地调整课程展示「教务课表 + 本地调整」以及「修改调整」「恢复原时间」', (tester) async {
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

      final provider = CourseScheduleProvider();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<CourseScheduleProvider>.value(value: provider),
            ChangeNotifierProvider<AuthProvider>(create: (_) => _TestAuthProvider()),
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
      expect(find.text('修改调整'), findsOneWidget);
      expect(find.text('恢复原时间'), findsOneWidget);
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
              affectedWeeks: {5, 6, 7, 8},
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
              affectedWeeks: {6},
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

  group('BrowsingHistoryScreen 浏览记录测试 (Section 30 & 43)', () {
    testWidgets('浏览记录界面正确渲染标签、记录与清空按钮', (tester) async {
      final repo = BrowsingHistoryRepository();
      await repo.recordVisit(
        targetId: '99',
        type: BrowsingHistoryType.campusNews,
        title: '2026-2027学年开学通知',
        author: '教务处',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: BrowsingHistoryScreen(),
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
