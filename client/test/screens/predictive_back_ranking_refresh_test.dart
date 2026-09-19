import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:dio/dio.dart';

import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/models/course_evaluation.dart';
import 'package:shenliyuan/models/teacher.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_subject_provider.dart';
import 'package:shenliyuan/providers/major_provider.dart';
import 'package:shenliyuan/providers/teacher_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/campus_ranking_screen.dart';
import 'package:shenliyuan/screens/subject_ranking_detail_screen.dart';
import 'package:shenliyuan/screens/teacher_detail_screen.dart';

class _FakeCourseSubjectProvider extends ChangeNotifier
    implements CourseSubjectProvider {
  int loadSubjectDetailCallCount = 0;
  int loadSubjectsCallCount = 0;
  CourseSubjectDetail? stubDetail;

  @override
  List<CourseSubject> subjects = [
    const CourseSubject(
      id: 1,
      name: '高等数学',
      teacherCount: 1,
      ratingCount: 10,
      averageStar: 4.8,
    ),
  ];

  @override
  bool get isLoading => false;

  @override
  String? get error => null;

  @override
  bool get hasService => true;

  @override
  CourseSubjectDetail? detailById(int id) => stubDetail;

  @override
  Future<void> loadSubjects({bool force = false}) async {
    loadSubjectsCallCount++;
    notifyListeners();
  }

  @override
  Future<CourseSubjectDetail?> loadSubjectDetail(
    int subjectId, {
    bool force = false,
  }) async {
    loadSubjectDetailCallCount++;
    return stubDetail;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTeacherProvider extends ChangeNotifier implements TeacherProvider {
  final Map<int, TeacherDetailState> _states = {};
  final List<Teacher> _teachers = [];

  void setDetail(int teacherId, TeacherDetailState state) {
    _states[teacherId] = state;
    notifyListeners();
  }

  @override
  TeacherDetailState detailOf(int teacherId) {
    return _states[teacherId] ?? TeacherDetailState();
  }

  @override
  Future<void> loadTeacherDetail(int teacherId, {bool force = false}) async {}

  @override
  Future<void> loadTeachers({String? query}) async {}

  @override
  List<Teacher> get teachers => _teachers;

  @override
  bool get isLoading => false;

  @override
  String? get errorMessage => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  group('预测性返回与评价详情页刷新链路测试', () {
    testWidgets('TeacherDetailScreen 与 SubjectRankingDetailScreen 的 canPop 联动 ThemeProvider.predictiveBack',
        (tester) async {
      final themeProvider = ThemeProvider(loadOnStart: false);
      await themeProvider.loadThemeForTesting();
      final fakeTeacherProvider = _FakeTeacherProvider();
      final fakeCourseSubjectProvider = _FakeCourseSubjectProvider();
      final authProvider = AuthProvider(Dio());

      fakeTeacherProvider.setDetail(
        101,
        TeacherDetailState(
          isLoading: false,
          teacher: Teacher(
            id: 101,
            name: '张三',
            course: '高等数学',
            createdAt: DateTime.now(),
          ),
        ),
      );

      Widget buildApp() {
        return MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
            ChangeNotifierProvider<TeacherProvider>.value(
              value: fakeTeacherProvider,
            ),
            ChangeNotifierProvider<CourseSubjectProvider>.value(
              value: fakeCourseSubjectProvider,
            ),
          ],
          child: const MaterialApp(
            home: TeacherDetailScreen(
              teacherId: 101,
              teacherName: '张三',
            ),
          ),
        );
      }

      // 1. 默认状态：predictiveBack 为 false，PopScope.canPop 必须为 false
      await tester.pumpWidget(buildApp());
      await tester.pumpAndSettle();

      expect(themeProvider.predictiveBack, isFalse);
      PopScope popScope = tester.widget<PopScope>(
        find.byWidgetPredicate((w) => w is PopScope).first,
      );
      expect(popScope.canPop, isFalse);

      // 2. 开启预测性返回：predictiveBack 为 true，PopScope.canPop 必须为 true
      await themeProvider.setPredictiveBack(true);
      await tester.pumpAndSettle();

      expect(themeProvider.predictiveBack, isTrue);
      popScope = tester.widget<PopScope>(
        find.byWidgetPredicate((w) => w is PopScope).first,
      );
      expect(popScope.canPop, isTrue);
    });

    testWidgets('开启预测性返回时，手势返回 (Route 结果为 null) 仍然触发上一级详情数据重新加载',
        (tester) async {
      final themeProvider = ThemeProvider(loadOnStart: false);
      await themeProvider.loadThemeForTesting();
      await themeProvider.setPredictiveBack(true);
      expect(themeProvider.predictiveBack, isTrue);

      final fakeTeacherProvider = _FakeTeacherProvider();
      fakeTeacherProvider.setDetail(
        101,
        TeacherDetailState(
          isLoading: false,
          teacher: Teacher(
            id: 101,
            name: '张三',
            course: '高等数学',
            createdAt: DateTime.now(),
          ),
        ),
      );

      final fakeCourseSubjectProvider = _FakeCourseSubjectProvider();
      fakeCourseSubjectProvider.stubDetail = const CourseSubjectDetail(
        id: 1,
        name: '高等数学',
        teacherCount: 1,
        ratingCount: 10,
        averageStar: 4.8,
        teachers: [
          CourseSubjectTeacher(
            id: 101,
            name: '张三',
            averageStar: 4.8,
            ratingCount: 10,
          ),
        ],
      );

      final authProvider = AuthProvider(Dio());

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
            ChangeNotifierProvider<TeacherProvider>.value(
              value: fakeTeacherProvider,
            ),
            ChangeNotifierProvider<CourseSubjectProvider>.value(
              value: fakeCourseSubjectProvider,
            ),
          ],
          child: const MaterialApp(
            home: SubjectRankingDetailScreen(
              subjectId: 1,
              subjectName: '高等数学',
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 初次加载详情：计数应为 1
      expect(fakeCourseSubjectProvider.loadSubjectDetailCallCount, equals(1));
      expect(find.text('张三'), findsOneWidget);

      // 点击进入教师详情页
      await tester.tap(find.text('张三'));
      await tester.pumpAndSettle();

      expect(find.text('教师评价'), findsOneWidget);

      // 模拟预测性返回手势触发系统 pop (此时 Route pop 结果为 null)
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop(null);
      await tester.pumpAndSettle();

      // 返回到学科详情页，验证即使返回结果为 null，也重新触发了详情重新加载 (_loadDetail)
      expect(find.text('教师评价'), findsNothing);
      expect(find.text('高等数学'), findsWidgets);
      expect(fakeCourseSubjectProvider.loadSubjectDetailCallCount, equals(2));
    });

    testWidgets('从学科详情页手势返回时 (Route 结果为 null)，校园榜 (CampusRankingScreen) 自动刷新学科列表',
        (tester) async {
      final themeProvider = ThemeProvider(loadOnStart: false);
      await themeProvider.loadThemeForTesting();
      await themeProvider.setPredictiveBack(true);

      final fakeCourseSubjectProvider = _FakeCourseSubjectProvider();
      fakeCourseSubjectProvider.stubDetail = const CourseSubjectDetail(
        id: 1,
        name: '高等数学',
        teacherCount: 1,
        ratingCount: 10,
        averageStar: 4.8,
        teachers: [
          CourseSubjectTeacher(
            id: 101,
            name: '张三',
            averageStar: 4.8,
            ratingCount: 10,
          ),
        ],
      );

      final fakeTeacherProvider = _FakeTeacherProvider();
      final authProvider = AuthProvider(Dio());
      final majorProvider = MajorProvider(Dio());

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
            ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
            ChangeNotifierProvider<TeacherProvider>.value(
              value: fakeTeacherProvider,
            ),
            ChangeNotifierProvider<CourseSubjectProvider>.value(
              value: fakeCourseSubjectProvider,
            ),
            ChangeNotifierProvider<MajorProvider>.value(
              value: majorProvider,
            ),
          ],
          child: const MaterialApp(
            home: CampusRankingScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final countBefore = fakeCourseSubjectProvider.loadSubjectsCallCount;

      // 找到“高等数学”并点击进入学科详情
      expect(find.text('高等数学'), findsWidgets);
      await tester.tap(find.text('高等数学').first);
      await tester.pumpAndSettle();

      expect(find.byType(SubjectRankingDetailScreen), findsOneWidget);

      // 模拟预测性返回手势触发系统 pop (此时 Route pop 结果为 null)
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pop(null);
      await tester.pumpAndSettle();

      // 验证返回校园榜后重新调用了 loadSubjects(force: true)
      expect(find.byType(SubjectRankingDetailScreen), findsNothing);
      expect(
        fakeCourseSubjectProvider.loadSubjectsCallCount,
        greaterThan(countBefore),
      );
    });
  });
}

