import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/course_schedule_screen.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/features/campus_data/storage/schedule_cache_store.dart';
import 'package:shenliyuan/models/course_term.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

/// 无延迟的内存快照存储。不能用 YieldingPersonalSnapshotStore：
/// 它的 `Future.delayed(Duration.zero)` 在 testWidgets 的 FakeAsync 里、
/// 首次 pump 之前永远不会完成，会导致 setup await 挂死。
class _MemorySnapshotStore implements AccountScopedSnapshotStore {
  PersonalSnapshot? _snapshot;

  @override
  final String accountFingerprint = 'course-test-account';

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

/// 从表头里找到「学期标题  M/D - M/D」的周日期文本。
String? _weekHeaderText(WidgetTester tester) {
  final datePattern = RegExp(r'\d{1,2}/\d{1,2} - \d{1,2}/\d{1,2}');
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final data = text.data ?? '';
    if (datePattern.hasMatch(data)) return data;
  }
  return null;
}

void main() {
  testWidgets('课表中部横滑切周', (tester) async {
    final page = await _pumpCourse(tester);

    final before = _weekHeaderText(tester);
    expect(before, isNotNull);

    await tester.dragFrom(const Offset(220, 400), const Offset(-250, 0));
    await tester.pumpAndSettle();

    expect(_weekHeaderText(tester), isNot(before));

    await _disposeCourse(tester, page);
  });

  testWidgets('课表底部 120px 区域横滑仍可切周', (tester) async {
    final page = await _pumpCourse(tester);

    final before = _weekHeaderText(tester);
    expect(before, isNotNull);

    // 屏幕高度 800，底部 120px 即 y >= 680。旧行为在这里拒绝周横滑。
    await tester.dragFrom(const Offset(220, 760), const Offset(-250, 0));
    await tester.pumpAndSettle();

    expect(_weekHeaderText(tester), isNot(before));

    await _disposeCourse(tester, page);
  });
}

Future<_CourseTestPage> _pumpCourse(WidgetTester tester) async {
  AppPreferencesStore.setMockInitialValues({});
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  // 课表页会查询课程提醒后台保活状态；不 mock 的话平台通道 Future 永不完成，
  // 其 2s timeout 计时器会残留在测试结束时触发断言。
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
          Response(requestOptions: options, statusCode: 200, data: <dynamic>[]),
        );
      },
    ),
  );

  // 通过内存快照商店预置一门课程，让课表走「本地缓存优先」路径渲染周分页器。
  final snapshotStore = _MemorySnapshotStore();
  final scheduleProvider = CourseScheduleProvider(dio, (_) => snapshotStore);
  scheduleProvider.syncSessionContext('1', 'edu-1');
  // 测试字体 Ahem 下每个字符都是全宽，过长的学期标题会让表头行溢出；
  // 注入短标题保持 400x800 真实手机宽度下无布局误差。
  await scheduleProvider.switchTerm(
    const CourseTerm(
      id: '2026_3',
      year: '2026',
      semester: 3,
      title: '26 第一学期',
      isCurrent: true,
    ),
    loadCache: false,
  );
  final store = ScheduleCacheStore(
    appUserId: '1',
    sourceAccountId: 'edu-1',
    snapshotStore: snapshotStore,
  );
  await store.writeCourses(
    year: scheduleProvider.currentTerm.year,
    semester: scheduleProvider.currentTerm.semester,
    courses: [
      <String, dynamic>{
        'id': 1,
        'course_code': 'C1',
        'name': '高等数学',
        'teacher': '张老师',
        'location': 'A101',
        'color': '#6366F1',
        'weekday': 1,
        'start_section': 1,
        'end_section': 2,
        'weeks': <int>[
          for (var w = 1; w <= 20; w++) w,
        ],
      },
    ],
  );

  final auth = _CourseAuthProvider(client: dio);
  final eduProvider = _BoundEduProvider();
  final themeProvider = ThemeProvider(loadOnStart: false);

  final widget = MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<EduProvider>.value(value: eduProvider),
      ChangeNotifierProvider<CourseScheduleProvider>.value(
          value: scheduleProvider),
      ChangeNotifierProvider<ThemeProvider>.value(value: themeProvider),
    ],
    child: const MaterialApp(home: CourseScheduleScreen()),
  );
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();

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
