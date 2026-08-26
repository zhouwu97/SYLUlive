import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/course_term.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/course_schedule_screen.dart';
import 'package:shenliyuan/widgets/course/course_empty_state_card.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';

/// 无延迟的内存快照存储（与 course_week_swipe_test 一致，避免 FakeAsync 挂死）。
class _MemorySnapshotStore implements AccountScopedSnapshotStore {
  PersonalSnapshot? _snapshot;

  @override
  final String accountFingerprint = 'course-freshness-test-account';

  @override
  Future<void> clearUser() async {
    _snapshot = null;
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteType(PersonalDataType type) async {
    if (_snapshot?.type == type) _snapshot = null;
  }

  @override
  Future<PersonalSnapshot?> read({
    required PersonalDataType type,
    required String sourceSystem,
    required String sourceAccountId,
  }) async {
    final snapshot = _snapshot;
    if (snapshot == null || snapshot.type != type) return null;
    return PersonalSnapshot(
      appUserFingerprint: snapshot.appUserFingerprint,
      sourceAccountFingerprint: snapshot.sourceAccountFingerprint,
      type: snapshot.type,
      schemaVersion: snapshot.schemaVersion,
      encryptionVersion: snapshot.encryptionVersion,
      fetchedAt: snapshot.fetchedAt,
      expiresAt: snapshot.expiresAt,
      contentHash: snapshot.contentHash,
      payload: Map<String, dynamic>.from(snapshot.payload),
    );
  }

  @override
  Future<void> write({
    required PersonalDataType type,
    required int schemaVersion,
    required String sourceSystem,
    required String sourceAccountId,
    required Map<String, dynamic> payload,
    DateTime? fetchedAt,
    DateTime? expiresAt,
  }) async {
    _snapshot = PersonalSnapshot(
      appUserFingerprint: accountFingerprint,
      sourceAccountFingerprint: 'test-source',
      type: type,
      schemaVersion: schemaVersion,
      encryptionVersion: 1,
      fetchedAt: fetchedAt ?? DateTime.now().toUtc(),
      expiresAt: expiresAt,
      contentHash: 'test-content-hash',
      payload: Map<String, dynamic>.from(payload),
    );
  }
}

class _CourseAuthProvider extends ChangeNotifier implements AuthProvider {
  _CourseAuthProvider({required this.client});

  final Dio client;

  @override
  User? get user =>
      User(id: 1, studentId: 's1', nickname: '测试用户', createdAt: DateTime(2026));

  @override
  bool get isLoggedIn => true;

  @override
  int get sessionGeneration => 0;

  @override
  int get accountSessionEpoch => 0;

  @override
  Dio get dio => client;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BoundEduProvider extends EduProvider {
  _BoundEduProvider() : super(Dio());

  @override
  bool get isBound => true;

  @override
  bool get isStatusLoaded => true;

  @override
  void setUserId(String userId) {}

  @override
  Future<void> ensureStatusLoaded() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 模拟 EduProvider 先恢复“已绑定”状态、稍后才恢复来源学号的竞态。
class _DelayedSourceEduProvider extends EduProvider {
  _DelayedSourceEduProvider() : super(Dio());

  String _sourceAccountId = '';

  @override
  bool get isBound => true;

  @override
  bool get isStatusLoaded => true;

  @override
  String get studentId => _sourceAccountId;

  @override
  void setUserId(String userId) {}

  void restoreSourceAccount(String sourceAccountId) {
    _sourceAccountId = sourceAccountId;
    notifyListeners();
  }

  @override
  Future<void> ensureStatusLoaded() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 写入一份有效课表快照，fetchedAt 可指定（用于“上次同步”文案测试）。
Future<void> _seedVault(
  AccountScopedSnapshotStore store, {
  required DateTime fetchedAt,
  DateTime? semesterStart,
}) async {
  final configuredSemesterStart = semesterStart ?? DateTime.now();
  await store.write(
    type: PersonalDataType.schedule,
    schemaVersion: 1,
    sourceSystem: 'edu',
    sourceAccountId: 'edu-1',
    fetchedAt: fetchedAt.toUtc(),
    expiresAt: fetchedAt.add(const Duration(days: 14)).toUtc(),
    payload: {
      'terms': {
        '2026_3': {
          'courses': [
            {
              'id': 1,
              'course_code': 'C1',
              'name': '高等数学',
              'teacher': '张老师',
              'location': 'A101',
              'color': '#6366F1',
              'weekday': DateTime.now().weekday,
              'start_section': 1,
              'end_section': 2,
              'weeks': [for (var w = 1; w <= 20; w++) w],
            },
          ],
          'hidden_course_ids': <int>[],
          'semester_start': configuredSemesterStart.toUtc().toIso8601String(),
          'archives': <dynamic>[],
          'active_archive_id': null,
        },
      },
    },
  );
}

Future<_CourseTestPage> _pumpCourse(
  WidgetTester tester, {
  required CourseScheduleProvider scheduleProvider,
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1,
  Duration initialPump = const Duration(milliseconds: 50),
  bool settle = true,
}) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  // 课表页会查询课程提醒后台保活状态；不 mock 的话平台通道 Future 永不完成。
  const reminderChannel = MethodChannel('shenliyuan/course_reminders');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(reminderChannel, (call) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(reminderChannel, null);
  });

  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: <dynamic>[],
          ),
        );
      },
    ),
  );

  final auth = _CourseAuthProvider(client: dio);
  final eduProvider = _BoundEduProvider();
  final themeProvider = ThemeProvider(loadOnStart: false);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<EduProvider>.value(value: eduProvider),
        ChangeNotifierProvider<CourseScheduleProvider>.value(
          value: scheduleProvider,
        ),
        ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
      ],
      child: MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: themeMode,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: const CourseScheduleScreen(),
      ),
    ),
  );
  await tester.pump(initialPump);
  if (settle) await tester.pumpAndSettle();

  return _CourseTestPage(
    auth: auth,
    eduProvider: eduProvider,
    scheduleProvider: scheduleProvider,
    themeProvider: themeProvider,
  );
}

Future<void> _disposeCourse(WidgetTester tester, _CourseTestPage page) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
  page.auth.dispose();
  page.eduProvider.dispose();
  page.scheduleProvider.dispose();
  page.themeProvider.dispose();
}

CourseScheduleProvider _newProvider(
  AccountScopedSnapshotStore store, {
  Dio? dio,
}) {
  final provider = CourseScheduleProvider(dio ?? Dio(), (_) => store);
  provider.syncSessionContext('1', 'edu-1');
  provider.switchTerm(
    const CourseTerm(
      id: '2026_3',
      year: '2026',
      semester: 3,
      title: '26 第一学期',
      isCurrent: true,
    ),
    loadCache: false,
  );
  return provider;
}

void main() {
  setUp(() {
    // 必须先 mock 本地偏好，否则 syncSessionContext 的 discardUnownedLegacy
    // 会等一个永不完结的通道 Future，导致 loadLastFetchedAt 挂起。
    AppPreferencesStore.setMockInitialValues({});
  });

  testWidgets('本地课表今天同步显示同步时间', (tester) async {
    final store = _MemorySnapshotStore();
    await _seedVault(store, fetchedAt: DateTime.now());
    final provider = _newProvider(store);
    final page = await _pumpCourse(tester, scheduleProvider: provider);

    expect(find.textContaining('本地课表'), findsOneWidget);
    expect(find.textContaining('已同步'), findsOneWidget);

    await _disposeCourse(tester, page);
  });

  testWidgets('恢复前台只同步本地状态，不自动拉取教务课表', (tester) async {
    final store = _MemorySnapshotStore();
    await _seedVault(store, fetchedAt: DateTime.now());
    var eduRequestCount = 0;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/edu/courses') {
            eduRequestCount++;
          }
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.cancel,
            ),
          );
        },
      ),
    );
    final provider = _newProvider(store, dio: dio);
    final page = await _pumpCourse(tester, scheduleProvider: provider);

    final state = tester.state(find.byType(CourseScheduleScreen)) as dynamic;
    await state.refreshAfterResumeForTesting();

    expect(eduRequestCount, 0);
    await _disposeCourse(tester, page);
  });

  testWidgets('旧课表显示使用本地课表 N 天前同步', (tester) async {
    final store = _MemorySnapshotStore();
    await _seedVault(
      store,
      fetchedAt: DateTime.now().subtract(const Duration(days: 3)),
    );
    final provider = _newProvider(store);
    final page = await _pumpCourse(tester, scheduleProvider: provider);

    expect(find.textContaining('使用本地课表'), findsOneWidget);
    expect(find.textContaining('3 天前同步'), findsOneWidget);

    await _disposeCourse(tester, page);
  });

  testWidgets('当前周不显示回到本周，离开当前周后显示并点击返回', (tester) async {
    final store = _MemorySnapshotStore();
    await _seedVault(store, fetchedAt: DateTime.now());
    final provider = _newProvider(store);
    final page = await _pumpCourse(tester, scheduleProvider: provider);

    const pill = ValueKey('schedule-back-to-current-week');
    // 初始落在当前周：不显示 pill。
    expect(find.byKey(pill), findsNothing);

    // 向左横滑到下一周。
    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();

    // 离开当前周：显示 pill。
    expect(find.byKey(pill), findsOneWidget);

    // 点击 pill 回到当前周：pill 消失。
    await tester.tap(find.byKey(pill));
    await tester.pumpAndSettle();
    expect(find.byKey(pill), findsNothing);

    await _disposeCourse(tester, page);
  });

  testWidgets('回到本周操作位于顶部工具区，不额外占用表头行', (tester) async {
    final store = _MemorySnapshotStore();
    await _seedVault(store, fetchedAt: DateTime.now());
    final provider = _newProvider(store);
    final page = await _pumpCourse(tester, scheduleProvider: provider);

    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('schedule-back-to-current-week'));
    final syncStatus = find.textContaining('已同步');
    expect(button, findsOneWidget);
    expect(tester.getSize(button).width, greaterThanOrEqualTo(44));
    expect(
      tester.getTopLeft(button).dy,
      lessThan(tester.getTopLeft(syncStatus).dy),
    );

    await _disposeCourse(tester, page);
  });

  testWidgets('大字体深色模式下顶部回到本周操作不溢出', (tester) async {
    final store = _MemorySnapshotStore();
    await _seedVault(store, fetchedAt: DateTime.now());
    final provider = _newProvider(store);
    final page = await _pumpCourse(
      tester,
      scheduleProvider: provider,
      themeMode: ThemeMode.dark,
      textScale: 1.3,
    );

    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('schedule-back-to-current-week')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await _disposeCourse(tester, page);
  });

  testWidgets('课表菜单提供设置开学日期入口', (tester) async {
    final store = _MemorySnapshotStore();
    await _seedVault(store, fetchedAt: DateTime.now());
    final provider = _newProvider(store);
    final page = await _pumpCourse(tester, scheduleProvider: provider);

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置开学日期'));
    await tester.pumpAndSettle();

    expect(find.text('设置开学第一周'), findsOneWidget);

    await _disposeCourse(tester, page);
  });

  testWidgets('初始化首帧保留课表框架而不是透明空屏', (tester) async {
    final provider = _newProvider(_MemorySnapshotStore());
    final page = await _pumpCourse(
      tester,
      scheduleProvider: provider,
      initialPump: Duration.zero,
      settle: false,
    );

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('一'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _disposeCourse(tester, page);
  });

  testWidgets('初始化优先恢复缓存课表，不显示整页 loading', (tester) async {
    final store = _MemorySnapshotStore();
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    await _seedVault(store, fetchedAt: now, semesterStart: monday);
    final provider = _newProvider(store);
    expect(await provider.loadCachedCoursesIfAvailable(), isTrue);
    await provider.loadSemesterStart();
    final page = await _pumpCourse(
      tester,
      scheduleProvider: provider,
      initialPump: Duration.zero,
      settle: false,
    );

    expect(find.text('高等数学'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);

    await _disposeCourse(tester, page);
  });

  testWidgets('来源学号延迟恢复时不显示误导的课表拉取空状态', (tester) async {
    final store = _MemorySnapshotStore();
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    await _seedVault(
      store,
      fetchedAt: now,
      semesterStart: monday,
    );

    AppPreferencesStore.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const reminderChannel = MethodChannel('shenliyuan/course_reminders');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(reminderChannel, (call) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(reminderChannel, null);
    });

    final auth = _CourseAuthProvider(client: Dio());
    final edu = _DelayedSourceEduProvider();
    final themeProvider = ThemeProvider(loadOnStart: false);
    final scheduleProvider = CourseScheduleProvider(Dio(), (_) => store);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<EduProvider>.value(value: edu),
          ChangeNotifierProxyProvider2<AuthProvider, EduProvider,
              CourseScheduleProvider>(
            create: (_) => scheduleProvider,
            update: (_, auth, edu, schedule) => schedule!
              ..syncSessionContext(auth.user?.id.toString(), edu.studentId),
          ),
          ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
        ],
        child: MaterialApp(
          theme: ThemeData.light(),
          home: const CourseScheduleScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('schedule-session-restoring')),
      findsOneWidget,
    );
    expect(find.byType(CourseEmptyStateCard), findsNothing);
    expect(find.text('课表拉取'), findsNothing);

    edu.restoreSourceAccount('edu-1');
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsOneWidget);
    expect(find.byType(CourseEmptyStateCard), findsNothing);
    expect(find.text('课表拉取'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    auth.dispose();
    edu.dispose();
    themeProvider.dispose();
  });
}

class _CourseTestPage {
  const _CourseTestPage({
    required this.auth,
    required this.eduProvider,
    required this.scheduleProvider,
    required this.themeProvider,
  });

  final _CourseAuthProvider auth;
  final _BoundEduProvider eduProvider;
  final CourseScheduleProvider scheduleProvider;
  final ThemeProvider themeProvider;
}
