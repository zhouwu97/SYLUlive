import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/edu_academic_situation.dart';
import 'package:shenliyuan/models/edu_grade.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/screens/edu_grade_screen.dart';
import 'package:shenliyuan/utils/edu_semester_utils.dart';
import 'package:shenliyuan/utils/grade_screen_registry.dart';
import 'package:shenliyuan/widgets/edu_grade/grade_empty_state.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

enum _LoadMode { data, empty, error, loading }

class _MemoryAuthCredentialStore implements AuthCredentialStore {
  @override
  Future<void> clear() async {}

  @override
  Future<StoredAuthCredentials> read() async => const StoredAuthCredentials();

  @override
  Future<void> write({required String token, required String userJson}) async {}
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
  final String academicErrorMessage;
  final bool bound;
  final List<EduGrade> grades;
  final EduAcademicSituation academicSituation;
  final List<Completer<OperationResult<List<EduGrade>>>> _pendingGrades = [];

  String? activeUserId;
  int fetchGradesCallCount = 0;
  bool holdRefreshAfterInitial = false;

  _FakeEduProvider({
    this.gradeMode = _LoadMode.data,
    this.academicMode = _LoadMode.data,
    this.academicErrorMessage = '测试学业情况错误',
    this.bound = true,
    List<EduGrade>? grades,
    EduAcademicSituation? academicSituation,
  })  : grades = grades ?? _sampleGrades(),
        academicSituation = academicSituation ?? _sampleAcademicSituation(),
        super(Dio());

  @override
  bool get isBound => bound;

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
    fetchGradesCallCount++;
    if (holdRefreshAfterInitial && fetchGradesCallCount > 1) {
      final pending = Completer<OperationResult<List<EduGrade>>>();
      _pendingGrades.add(pending);
      return pending.future;
    }
    return switch (gradeMode) {
      _LoadMode.data => Future.value(OperationResult.ok(grades)),
      _LoadMode.empty => Future.value(OperationResult.ok(const <EduGrade>[])),
      _LoadMode.error => Future.value(OperationResult.fail('测试成绩错误')),
      _LoadMode.loading => _newPendingGradeRequest(),
    };
  }

  Future<OperationResult<List<EduGrade>>> _newPendingGradeRequest() {
    final pending = Completer<OperationResult<List<EduGrade>>>();
    _pendingGrades.add(pending);
    return pending.future;
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
  Future<OperationResult<EduAcademicSituation>> fetchAcademicSituation() async {
    return switch (academicMode) {
      _LoadMode.data => OperationResult.ok(academicSituation),
      _LoadMode.empty => OperationResult.ok(_emptyAcademicSituation()),
      _LoadMode.error => OperationResult.fail(academicErrorMessage),
      _LoadMode.loading => OperationResult.fail('测试不支持学业情况挂起'),
    };
  }

  void finishPendingGrades() {
    for (final pending in _pendingGrades) {
      if (!pending.isCompleted) {
        pending.complete(OperationResult.fail('测试结束'));
      }
    }
  }

  void completePendingGrade(
    int index,
    OperationResult<List<EduGrade>> result,
  ) {
    _pendingGrades[index].complete(result);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const gradeReminderChannel = MethodChannel('shenliyuan/grade_reminders');

  setUp(() {
    AppPreferencesStore.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(gradeReminderChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(gradeReminderChannel, null);
  });

  testWidgets('默认展示学期成绩，并可切换学业总览', (tester) async {
    final providers = await _pumpGradeScreen(tester);

    expect(find.text('离散数学'), findsOneWidget);
    expect(find.text('课程成绩'), findsOneWidget);

    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();

    expect(find.text('学分要求'), findsOneWidget);
    expect(find.text('3.52'), findsNothing);
    expect(find.text('高等数学'), findsNothing);
    expect(find.text('课程明细'), findsNothing);
    expect(find.text('课程列表学分'), findsNothing);
    expect(find.text('未知状态学分'), findsNothing);
    expect(find.textContaining('不代表已获得学分'), findsNothing);
    expect(find.text('毕业预警'), findsNothing);

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

    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();

    final overviewScroll =
        find.byKey(const ValueKey('grade_overview_scroll_view'));
    expect(_scrollPosition(tester, overviewScroll).pixels, 0);
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

    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();
    expect(find.text('高等数学'), findsNothing);

    auth.switchUser(_user(2));
    await tester.pumpAndSettle();

    expect(providers.edu.activeUserId, '2');
    expect(find.text('离散数学'), findsOneWidget);
    expect(find.text('高等数学'), findsNothing);
  });

  testWidgets('成绩加载状态只显示一个状态组件', (tester) async {
    final edu = _FakeEduProvider(gradeMode: _LoadMode.loading);
    await _pumpGradeScreen(tester, edu: edu, settle: false);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(GradeEmptyState), findsOneWidget);
    expect(find.text('成绩获取失败'), findsNothing);
    expect(find.text('当前学期暂无成绩'), findsNothing);

    edu.finishPendingGrades();
    await tester.pumpAndSettle();
  });

  testWidgets('成绩错误状态不会重复显示内容', (tester) async {
    await _pumpGradeScreen(
      tester,
      edu: _FakeEduProvider(gradeMode: _LoadMode.error),
    );

    expect(find.text('成绩获取失败'), findsOneWidget);
    expect(find.text('测试成绩错误'), findsOneWidget);
    expect(find.text('当前学期暂无成绩'), findsNothing);
  });

  testWidgets('成绩空数据和学业空数据均显示明确空状态', (tester) async {
    await _pumpGradeScreen(
      tester,
      edu: _FakeEduProvider(
        gradeMode: _LoadMode.empty,
        academicMode: _LoadMode.empty,
      ),
    );

    expect(find.text('当前学期暂无成绩'), findsOneWidget);
    expect(find.text('成绩获取失败'), findsNothing);
    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();

    expect(find.text('学分概览'), findsNothing);
    expect(find.text('暂无可汇总的课程学分数据'), findsNothing);
    expect(find.text('当前学业页面不提供课程明细'), findsNothing);
    expect(find.text('官方 GPA 获取失败'), findsNothing);
  });

  final courseStatusCases = <String, String>{
    'available': '高等数学',
    'empty': '教务系统当前未返回课程明细',
    'not_present': '当前学业页面不提供课程明细',
    'dynamic_source_unresolved': '课程明细可能通过其他接口加载，暂未完成识别',
    'parse_failed': '课程明细结构发生变化，暂时无法展示',
  };

  for (final entry in courseStatusCases.entries) {
    testWidgets('学业总览隐藏课程明细状态 ${entry.key}', (tester) async {
      await _pumpGradeScreen(
        tester,
        edu: _FakeEduProvider(
          academicSituation: _academicSituationWithStatus(entry.key),
        ),
      );
      await tester.tap(find.text('学业总览'));
      await tester.pumpAndSettle();

      expect(find.text('学分要求'), findsOneWidget);
      expect(find.text(entry.value), findsNothing);
      expect(find.text('课程明细'), findsNothing);
    });
  }

  testWidgets('学业总览错误状态不会与课程明细重复显示', (tester) async {
    await _pumpGradeScreen(
      tester,
      edu: _FakeEduProvider(academicMode: _LoadMode.error),
    );
    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();

    expect(find.text('官方 GPA 获取失败'), findsNothing);
    expect(find.text('测试学业情况错误'), findsNothing);
    expect(find.text('课程明细'), findsNothing);
    expect(find.text('暂无可展示的课程明细'), findsNothing);
  });

  testWidgets('学业页面结构变化时只显示错误，不展示全零概览', (tester) async {
    await _pumpGradeScreen(
      tester,
      edu: _FakeEduProvider(
        academicMode: _LoadMode.error,
        academicErrorMessage: '学业情况页面结构发生变化',
      ),
    );
    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();

    expect(find.text('官方 GPA 获取失败'), findsNothing);
    expect(find.text('学业情况页面结构发生变化'), findsNothing);
    expect(find.text('计划'), findsNothing);
    expect(find.text('课程列表学分'), findsNothing);
    expect(find.text('暂无可展示的课程明细'), findsNothing);
  });

  testWidgets('未登录和未绑定教务均结束加载并显示明确错误', (tester) async {
    await _pumpGradeScreen(
      tester,
      auth: _FakeAuthProvider(null),
    );
    expect(find.text('成绩获取失败'), findsOneWidget);
    expect(find.text('请先登录后查看成绩'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpGradeScreen(
      tester,
      edu: _FakeEduProvider(bound: false),
    );
    expect(find.text('成绩获取失败'), findsOneWidget);
    expect(find.text('请先绑定教务账号'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  for (final message in const <String>[
    '教务登录状态已失效，请重新绑定',
    '教务网络连接失败',
    'Python 教务服务暂时不可用',
    '学业情况页面结构发生变化',
  ]) {
    testWidgets('学业总览失败关闭：$message', (tester) async {
      await _pumpGradeScreen(
        tester,
        edu: _FakeEduProvider(
          academicMode: _LoadMode.error,
          academicErrorMessage: message,
        ),
      );
      await tester.tap(find.text('学业总览'));
      await tester.pumpAndSettle();

      expect(find.text(message), findsNothing);
      expect(find.text('课程列表学分'), findsNothing);
      expect(find.text('0.00'), findsNothing);
    });
  }

  testWidgets('学业总览展示隐私与毕业审核边界', (tester) async {
    await _pumpGradeScreen(tester);
    await tester.tap(find.text('学业总览'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('grade_overview_scroll_view')),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('学业数据来自学校教务系统'), findsOneWidget);
    expect(find.textContaining('不代表学校毕业审核结论'), findsOneWidget);
  });

  testWidgets('旧用户请求返回时不会写入新用户页面', (tester) async {
    final auth = _FakeAuthProvider(_user(1));
    final edu = _FakeEduProvider(gradeMode: _LoadMode.loading);
    await _pumpGradeScreen(tester, auth: auth, edu: edu, settle: false);
    await tester.pump();

    auth.switchUser(_user(2));
    await tester.pump();
    edu.completePendingGrade(
      0,
      OperationResult.ok([_grade('旧账号课程', grade: '99')]),
    );
    await tester.pump();
    expect(find.text('旧账号课程'), findsNothing);

    edu.completePendingGrade(
      1,
      OperationResult.ok([_grade('新账号课程', grade: '88')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('新账号课程'), findsOneWidget);
  });

  testWidgets('连续点击刷新只发出一个进行中的请求', (tester) async {
    final edu = _FakeEduProvider()..holdRefreshAfterInitial = true;
    await _pumpGradeScreen(tester, edu: edu);
    expect(edu.fetchGradesCallCount, 1);

    await tester.tap(find.byTooltip('成绩管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新成绩'));
    await tester.pump();
    await tester.tap(find.text('刷新成绩'));
    await tester.pump();
    expect(edu.fetchGradesCallCount, 2);

    edu.finishPendingGrades();
    await tester.pumpAndSettle();
  });

  testWidgets('初始历史学期参数能够切换并加载', (tester) async {
    final current = EduSemester.current();
    final historicalYear = '${int.parse(current.year) - 1}';
    await _pumpGradeScreen(
      tester,
      screen: EduGradeScreen(
        initialYear: historicalYear,
        initialSemester: EduSemester.first,
      ),
    );

    expect(find.textContaining(historicalYear), findsWidgets);
    expect(find.text('离散数学'), findsOneWidget);
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
  EduGradeScreen screen = const EduGradeScreen(),
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
      child: MaterialApp(home: screen),
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
    'courses_status': 'available',
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
    'courses_status': 'not_present',
    'courses': const <Object>[],
  });
}

EduAcademicSituation _academicSituationWithStatus(String status) {
  if (status == 'available') return _sampleAcademicSituation();
  return EduAcademicSituation.fromJson({
    'success': true,
    'all_gpa': 3.52,
    'degree_gpa': 3.68,
    'total_courses': 5,
    'passed_courses': 1,
    'failed_courses': 1,
    'in_progress_courses': 1,
    'not_started_courses': 1,
    'courses_status': status,
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
