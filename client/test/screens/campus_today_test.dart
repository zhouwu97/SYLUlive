import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shenliyuan/models/course_term.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/campus_screen.dart';
import 'package:shenliyuan/screens/course_schedule_screen.dart';
import 'package:shenliyuan/screens/exam_schedule_screen.dart';

/// 可控课表 Provider：直接注入课程与学期起点，避免走真实保险箱/网络。
class _FakeCourseScheduleProvider extends CourseScheduleProvider {
  _FakeCourseScheduleProvider({
    required List<CourseBlock> seededCourses,
    DateTime? seededSemesterStart,
    this.throwOnLoad = false,
  })  : _seededCourses = seededCourses,
        _seededSemesterStart = seededSemesterStart,
        super();

  final List<CourseBlock> _seededCourses;
  final DateTime? _seededSemesterStart;
  final bool throwOnLoad;

  @override
  List<CourseBlock> get courses => _seededCourses;

  @override
  DateTime? get semesterStart => _seededSemesterStart;

  // 课表页表头用学期标题；测试字体 Ahem 下长标题会溢出，注入短标题。
  @override
  CourseTerm get currentTerm => const CourseTerm(
        id: '2026_3',
        year: '2026',
        semester: 3,
        title: '26 第一学期',
        isCurrent: true,
      );

  @override
  Future<bool> loadCachedCoursesIfAvailable() async {
    if (throwOnLoad) throw Exception('cache unavailable');
    return _seededCourses.isNotEmpty;
  }

  @override
  Future<void> loadSemesterStart() async {
    if (throwOnLoad) throw Exception('semester start unavailable');
  }

  @override
  void setUserId(String userId) {}

  @override
  void syncSessionContext(String? userId, String? sourceAccountId) {}

  @override
  int? getAcademicWeek(DateTime date) {
    final start = _seededSemesterStart;
    if (start == null) return null;
    final diff = date.difference(start).inDays;
    if (diff < 0) return null;
    return (diff / 7).floor() + 1;
  }

  @override
  bool isCourseActive(CourseBlock course, int academicWeek) => true;
}

class _AuthProviderFake extends ChangeNotifier implements AuthProvider {
  _AuthProviderFake({required this.loggedIn, required User? user})
      : _user = user;

  final bool loggedIn;
  final User? _user;

  @override
  bool get isLoggedIn => loggedIn;

  @override
  User? get user => _user;

  @override
  int get sessionGeneration => 0;

  @override
  int get accountSessionEpoch => 0;

  @override
  Dio get dio => Dio();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BoundEduProvider extends EduProvider {
  _BoundEduProvider() : super(Dio());

  @override
  bool get isBound => true;

  @override
  bool get isStatusLoaded => true;

  @override
  String get studentId => '2403130233';

  @override
  void setUserId(String userId) {}

  @override
  Future<void> ensureStatusLoaded() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 一周内第 3 节（10:00-10:45）的课程，用于固定 now 下稳定的「下一节课」。
CourseBlock _courseFor(DateTime now) => CourseBlock(
      id: 1,
      courseCode: 'C1',
      name: '高等数学',
      teacher: '张老师',
      location: 'A101',
      color: '#6366F1',
      weekday: now.weekday,
      startSection: 3,
      endSection: 3,
      weeks: const [1],
    );

Map<String, dynamic> _examJson(DateTime now) {
  final start = now.add(const Duration(days: 2));
  return {
    'name': '数据结构',
    'startTime': start.toIso8601String(),
    'endTime': start.add(const Duration(hours: 2)).toIso8601String(),
    'location': '机房',
    'semester': '',
  };
}

Future<void> _pumpCampus(
  WidgetTester tester, {
  required DateTime now,
  CourseScheduleProvider? scheduleProvider,
  Map<String, Object>? initialPrefs,
  bool dark = false,
  double textScale = 1.0,
  bool navHarness = false,
}) async {
  AppPreferencesStore.setMockInitialValues(initialPrefs ?? const {});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  if (navHarness) {
    // 课表页会查询课程提醒后台保活状态；不 mock 的话平台通道 Future 永不完成。
    const reminderChannel = MethodChannel('shenliyuan/course_reminders');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(reminderChannel, (call) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(reminderChannel, null);
    });
  }

  final providers = <SingleChildWidget>[
    ChangeNotifierProvider<ThemeProvider>.value(
      value: ThemeProvider(loadOnStart: false),
    ),
    if (scheduleProvider != null)
      ChangeNotifierProvider<CourseScheduleProvider>.value(
        value: scheduleProvider,
      ),
    if (navHarness) ...[
      ChangeNotifierProvider<AuthProvider>.value(
        value: _AuthProviderFake(
          loggedIn: true,
          user: User(
            id: 1,
            studentId: 's1',
            nickname: '测试用户',
            createdAt: DateTime(2026),
          ),
        ),
      ),
      ChangeNotifierProvider<EduProvider>.value(value: _BoundEduProvider()),
    ],
  ];

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: MultiProvider(
        providers: providers,
        child: MaterialApp(
          theme: dark ? ThemeData.dark(useMaterial3: true) : null,
          home: CampusScreen(nowProvider: () => now),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  // 固定「今天」：2026-08-10 09:00，保证课程与考试计算稳定。
  final now = DateTime(2026, 8, 10, 9, 0);
  // 本周周一（date-only）作为学期起点 → 今天即第 1 教学周。
  final monday = now.subtract(Duration(days: now.weekday - 1));
  final semesterStart = DateTime(monday.year, monday.month, monday.day);

  testWidgets('无可用数据时不显示今日卡片', (tester) async {
    await _pumpCampus(tester, now: now);
    expect(find.text('今日'), findsNothing);
  });

  testWidgets('只有考试数据时只显示考试项', (tester) async {
    await _pumpCampus(
      tester,
      now: now,
      initialPrefs: {'local_exams': jsonEncode([_examJson(now)])},
    );
    expect(find.text('今日'), findsOneWidget);
    expect(find.textContaining('考试 · 数据结构'), findsOneWidget);
    expect(find.textContaining('下一节课'), findsNothing);
  });

  testWidgets('课程 + 考试两项都显示且顺序稳定（课程在上）', (tester) async {
    final schedule = _FakeCourseScheduleProvider(
      seededCourses: [_courseFor(now)],
      seededSemesterStart: semesterStart,
    );
    await _pumpCampus(
      tester,
      now: now,
      scheduleProvider: schedule,
      initialPrefs: {'local_exams': jsonEncode([_examJson(now)])},
    );
    expect(find.text('今日'), findsOneWidget);
    expect(find.textContaining('下一节课 · 高等数学'), findsOneWidget);
    expect(find.textContaining('考试 · 数据结构'), findsOneWidget);

    final courseY = tester
        .getTopLeft(find.textContaining('下一节课 · 高等数学'))
        .dy;
    final examY = tester.getTopLeft(find.textContaining('考试 · 数据结构')).dy;
    expect(courseY, lessThan(examY), reason: '课程项应排在考试项之前');
  });

  testWidgets('课表数据异常时考试项仍正常展示（独立降级）', (tester) async {
    final schedule = _FakeCourseScheduleProvider(
      seededCourses: [_courseFor(now)],
      seededSemesterStart: null,
      throwOnLoad: true,
    );
    await _pumpCampus(
      tester,
      now: now,
      scheduleProvider: schedule,
      initialPrefs: {'local_exams': jsonEncode([_examJson(now)])},
    );
    expect(find.textContaining('下一节课'), findsNothing);
    expect(find.textContaining('考试 · 数据结构'), findsOneWidget);
  });

  testWidgets('点击课程项进入课表页', (tester) async {
    final schedule = _FakeCourseScheduleProvider(
      seededCourses: [_courseFor(now)],
      seededSemesterStart: semesterStart,
    );
    await _pumpCampus(
      tester,
      now: now,
      scheduleProvider: schedule,
      navHarness: true,
    );
    await tester.tap(find.textContaining('下一节课 · 高等数学'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CourseScheduleScreen), findsOneWidget);
  });

  testWidgets('点击考试项进入考试页', (tester) async {
    await _pumpCampus(
      tester,
      now: now,
      initialPrefs: {'local_exams': jsonEncode([_examJson(now)])},
    );
    await tester.tap(find.textContaining('考试 · 数据结构'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // 考试页的学期 DropdownButton 在测试字体 Ahem 下存在既有溢出
    //（exam_schedule_screen 非本次改动）；本用例只验证跳转成功。
    tester.takeException();
    expect(find.byType(ExamScheduleScreen), findsOneWidget);
  });

  testWidgets('1.3 倍字号下今日卡片不产生布局异常', (tester) async {
    final schedule = _FakeCourseScheduleProvider(
      seededCourses: [_courseFor(now)],
      seededSemesterStart: semesterStart,
    );
    await _pumpCampus(
      tester,
      now: now,
      scheduleProvider: schedule,
      initialPrefs: {'local_exams': jsonEncode([_examJson(now)])},
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('今日'), findsOneWidget);
  });

  testWidgets('暗色主题下今日卡片正常展示', (tester) async {
    final schedule = _FakeCourseScheduleProvider(
      seededCourses: [_courseFor(now)],
      seededSemesterStart: semesterStart,
    );
    await _pumpCampus(
      tester,
      now: now,
      scheduleProvider: schedule,
      initialPrefs: {'local_exams': jsonEncode([_examJson(now)])},
      dark: true,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('今日'), findsOneWidget);
    expect(find.textContaining('下一节课 · 高等数学'), findsOneWidget);
    expect(find.textContaining('考试 · 数据结构'), findsOneWidget);
  });
}
