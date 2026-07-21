import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shenliyuan/models/edu_academic_situation.dart';
import 'package:shenliyuan/models/edu_grade.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/screens/edu_grade_screen.dart';
import 'package:shenliyuan/utils/edu_semester_utils.dart';
import 'package:shenliyuan/utils/grade_screen_registry.dart';
import 'package:shenliyuan/widgets/edu_grade/grade_empty_state.dart';

enum _LoadMode { data, empty, error, loading }

class _MemoryAuthCredentialStore implements AuthCredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<void> deleteEduPassword(String studentId) async {}

  @override
  Future<StoredAuthCredentials> read() async => const StoredAuthCredentials();

  @override
  Future<String?> readEduPassword(String studentId) async => null;

  @override
  Future<void> write({required String token, required String userJson}) async {}

  @override
  Future<void> writeEduPassword(String studentId, String password) async {}
}

class _FakeAuthProvider extends AuthProvider {
  User? _currentUser;

  _FakeAuthProvider(this._currentUser)
      : super(
          Dio(),
          credentialStore: _MemoryAuthCredentialStore(),
          loadStoredAuth: false,
          onAuthenticated: () {},
        );

  @override
  User? get user => _currentUser;

  void switchUser(User user) {
    _currentUser = user;
    notifyListeners();
  }
}

class _FakeEduProvider extends EduProvider {
  final _LoadMode gradeMode;
  final _LoadMode academicMode;
  final List<EduGrade> grades;
  final EduAcademicSituation academicSituation;
  final Completer<OperationResult<List<EduGrade>>> _pendingGrades =
      Completer<OperationResult<List<EduGrade>>>();

  String? activeUserId;

  _FakeEduProvider({
    this.gradeMode = _LoadMode.data,
    this.academicMode = _LoadMode.data,
    List<EduGrade>? grades,
    EduAcademicSituation? academicSituation,
  })  : grades = grades ?? _sampleGrades(),
        academicSituation = academicSituation ?? _sampleAcademicSituation(),
        super(Dio());

  @override
  bool get isBound => true;

  @override
  int get enrollmentYear => 2024;

  @override
  void setUserId(String userId) {
    activeUserId = userId;
  }

  @override
  Future<void> ensureStatusLoaded() async {}

  @override
  GradeCacheEntry? getCachedGrades(String year, int semester) {
    if (gradeMode != _LoadMode.data) return null;
    return GradeCacheEntry(grades: grades, updatedAt: DateTime(2026, 7, 21));
  }

  @override
  Future<OperationResult<List<EduGrade>>> fetchGrades(
    String year,
    int semester,
  ) {
    return switch (gradeMode) {
      _LoadMode.data => Future.value(OperationResult.ok(grades)),
      _LoadMode.empty => Future.value(OperationResult.ok(const <EduGrade>[])),
      _LoadMode.error => Future.value(OperationResult.fail('测试成绩错误')),
      _LoadMode.loading => _pendingGrades.future,
    };
  }

  @override
  AcademicSituationCacheEntry? getCachedAcademicSituation() {
    if (academicMode != _LoadMode.data) return null;
    return AcademicSituationCacheEntry(
      data: academicSituation,
      updatedAt: DateTime(2026, 7, 21),
    );
  }

  @override
  Future<OperationResult<EduAcademicSituation>> fetchAcademicSituation({
    bool forceRefresh = false,
  }) async {
    return switch (academicMode) {
      _LoadMode.data => OperationResult.ok(academicSituation),
      _LoadMode.empty => OperationResult.ok(_emptyAcademicSituation()),
      _LoadMode.error => OperationResult.fail('测试学业情况错误'),
      _LoadMode.loading => OperationResult.fail('测试不支持学业情况挂起'),
    };
  }

  void finishPendingGrades() {
    if (!_pendingGrades.isCompleted) {
      _pendingGrades.complete(OperationResult.fail('测试结束'));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gradeReminderChannel = MethodChannel('shenliyuan/grade_reminders');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(gradeReminderChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(gradeReminderChannel, null);
  });

  testWidgets('默认展示学期成绩，并可切换学业总览和毕业预警空状态', (tester) async {
    final providers = await _pumpGradeScreen(tester);

    expect(find.text('离散数学'), findsOneWidget);
    expect(find.text('课程成绩'), findsOneWidget);

    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();

    expect(find.text('3.52'), findsOneWidget);
    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('课程列表学分'), findsOneWidget);
    expect(find.text('未知状态学分'), findsOneWidget);
    expect(find.textContaining('不代表已获得学分'), findsOneWidget);

    await tester.tap(find.text('毕业预警'));
    await tester.pumpAndSettle();

    expect(find.text('暂无毕业预警数据'), findsOneWidget);
    expect(find.textContaining('暂未接入预警数据'), findsOneWidget);
    expect(find.textContaining('高风险'), findsNothing);

    providers.edu.finishPendingGrades();
  });

  testWidgets('切换栏固定，长列表切换到新视图时从顶部开始', (tester) async {
    final longGrades = List<EduGrade>.generate(
      40,
      (index) => _grade('课程 $index', grade: '${60 + index % 40}'),
    );
    await _pumpGradeScreen(
      tester,
      edu: _FakeEduProvider(grades: longGrades),
    );

    final tabs = find.byKey(const ValueKey('grade_section_tabs'));
    final termScroll = find.byKey(const ValueKey('grade_term_scroll_view'));
    final tabsTop = tester.getTopLeft(tabs).dy;

    await tester.drag(termScroll, const Offset(0, -1800));
    await tester.pump();

    expect(_scrollPosition(tester, termScroll).pixels, greaterThan(0));
    expect(tester.getTopLeft(tabs).dy, tabsTop);

    await tester.tap(find.text('毕业预警'));
    await tester.pumpAndSettle();

    final warningScroll =
        find.byKey(const ValueKey('grade_warning_scroll_view'));
    expect(_scrollPosition(tester, warningScroll).pixels, 0);
    expect(find.text('暂无毕业预警数据'), findsOneWidget);
  });

  testWidgets('成绩深链返回学期成绩视图并滚动到顶部', (tester) async {
    await _pumpGradeScreen(tester);
    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();

    final current = EduSemester.current();
    expect(
      await GradeScreenRegistry.trySwitch(current.year, current.semester),
      isTrue,
    );
    await tester.pumpAndSettle();

    expect(find.text('离散数学'), findsOneWidget);
    final termScroll = find.byKey(const ValueKey('grade_term_scroll_view'));
    expect(_scrollPosition(tester, termScroll).pixels, 0);
  });

  testWidgets('切换用户后恢复默认学期成绩视图', (tester) async {
    final auth = _FakeAuthProvider(_user(1));
    final providers = await _pumpGradeScreen(tester, auth: auth);

    await tester.tap(find.text('毕业预警'));
    await tester.pumpAndSettle();
    expect(find.text('暂无毕业预警数据'), findsOneWidget);

    auth.switchUser(_user(2));
    await tester.pumpAndSettle();

    expect(providers.edu.activeUserId, '2');
    expect(find.text('离散数学'), findsOneWidget);
    expect(find.text('暂无毕业预警数据'), findsNothing);
  });

  testWidgets('成绩加载状态只显示一个状态组件', (tester) async {
    final edu = _FakeEduProvider(gradeMode: _LoadMode.loading);
    await _pumpGradeScreen(tester, edu: edu, settle: false);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(GradeEmptyState), findsOneWidget);
    expect(find.text('成绩加载失败'), findsNothing);
    expect(find.text('暂无成绩'), findsNothing);

    edu.finishPendingGrades();
    await tester.pumpAndSettle();
  });

  testWidgets('成绩错误状态不会重复显示内容', (tester) async {
    await _pumpGradeScreen(
      tester,
      edu: _FakeEduProvider(gradeMode: _LoadMode.error),
    );

    expect(find.text('成绩加载失败'), findsOneWidget);
    expect(find.text('测试成绩错误'), findsOneWidget);
    expect(find.text('暂无成绩'), findsNothing);
  });

  testWidgets('成绩空数据和学业空数据均显示明确空状态', (tester) async {
    await _pumpGradeScreen(
      tester,
      edu: _FakeEduProvider(
        gradeMode: _LoadMode.empty,
        academicMode: _LoadMode.empty,
      ),
    );

    expect(find.text('暂无成绩'), findsOneWidget);
    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();

    expect(find.text('暂无可汇总的课程学分数据'), findsOneWidget);
    expect(find.text('暂无学业课程明细'), findsOneWidget);
    expect(find.text('官方 GPA 获取失败'), findsNothing);
  });

  testWidgets('学业总览错误状态不会与课程明细重复显示', (tester) async {
    await _pumpGradeScreen(
      tester,
      edu: _FakeEduProvider(academicMode: _LoadMode.error),
    );
    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();

    expect(find.text('官方 GPA 获取失败'), findsOneWidget);
    expect(find.text('测试学业情况错误'), findsOneWidget);
    expect(find.text('课程明细'), findsNothing);
    expect(find.text('暂无学业课程明细'), findsNothing);
  });
}

class _TestProviders {
  final _FakeAuthProvider auth;
  final _FakeEduProvider edu;

  const _TestProviders(this.auth, this.edu);
}

Future<_TestProviders> _pumpGradeScreen(
  WidgetTester tester, {
  _FakeAuthProvider? auth,
  _FakeEduProvider? edu,
  bool settle = true,
}) async {
  final testAuth = auth ?? _FakeAuthProvider(_user(1));
  final testEdu = edu ?? _FakeEduProvider();

  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: testAuth),
        ChangeNotifierProvider<EduProvider>.value(value: testEdu),
      ],
      child: const MaterialApp(home: EduGradeScreen()),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return _TestProviders(testAuth, testEdu);
}

ScrollPosition _scrollPosition(WidgetTester tester, Finder scrollView) {
  final scrollable = find.descendant(
    of: scrollView,
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable).position;
}

User _user(int id) {
  return User(
    id: id,
    studentId: '2024000$id',
    nickname: '测试用户$id',
    createdAt: DateTime(2024),
  );
}

List<EduGrade> _sampleGrades() => <EduGrade>[
      _grade('离散数学', grade: '88'),
      _grade('大学物理', grade: '55', passed: false),
    ];

EduGrade _grade(
  String name, {
  required String grade,
  bool? passed = true,
}) {
  return EduGrade.fromJson({
    'name': name,
    'grade': grade,
    'credits': 3,
    'gpa': passed == false ? 0 : 3.7,
    'is_degree': true,
  });
}

EduAcademicSituation _sampleAcademicSituation() {
  return EduAcademicSituation.fromJson({
    'success': true,
    'all_gpa': 3.52,
    'degree_gpa': 3.68,
    'total_courses': 5,
    'passed_courses': 1,
    'failed_courses': 1,
    'in_progress_courses': 1,
    'not_started_courses': 1,
    'courses': [
      _academicCourse('高等数学', 4, effectivePassed: true),
      _academicCourse('大学物理', 3, effectivePassed: false),
      _academicCourse('操作系统', 3, studyStatus: '在读'),
      _academicCourse('毕业设计', 8, studyStatus: '未修'),
      _academicCourse('创新实践', 2),
    ],
  });
}

EduAcademicSituation _emptyAcademicSituation() {
  return EduAcademicSituation.fromJson({
    'success': true,
    'courses': const <Object>[],
  });
}

Map<String, dynamic> _academicCourse(
  String name,
  double credits, {
  bool? effectivePassed,
  String? studyStatus,
}) {
  return {
    'course_name': name,
    'course_code': name,
    'credits': credits,
    'effective_grade': effectivePassed == true
        ? '88'
        : effectivePassed == false
            ? '55'
            : null,
    'effective_passed': effectivePassed,
    'study_status': studyStatus,
  };
}
