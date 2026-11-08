import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;
import 'package:provider/provider.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_account_config_client.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_adapters.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_router_repository.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/domain/academic_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_gate.dart';
import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
import 'package:shenliyuan/features/academic/storage/local_academic_account_store.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/schedule_cache_store.dart';
import 'package:shenliyuan/models/course_term.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/providers/theme_provider.dart';
import 'package:shenliyuan/screens/course_schedule_screen.dart';
import 'package:shenliyuan/theme/app_theme.dart';

import '../../helpers/golden_viewport.dart';
import '../../helpers/load_test_fonts.dart';
import '../../helpers/personal_snapshot_test_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadTestFonts);

  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  tearDown(() => AcademicPersistenceRegistry.clear('1001'));

  test('旧连接关闭记录不能阻止已重新连接身份的课表落盘及冷启动恢复', () async {
    final h = await _ScheduleHarness.create();
    addTearDown(h.close);
    const identity = _ScheduleHarness.identity;
    // 旧生命周期键保留关闭状态，新账号表已在重新连接时确认启用。
    await h.preferences.setBool(
        'academic_lifecycle_${identity.storageId}_connected', false);
    expect(AcademicConnectionStore(identity, h.preferences).connected, isTrue);
    await h.start();
    final count = await h.schedule.applyFetchedCourses([
      {
        'course_code': 'RECONNECT-1',
        'name': '重新连接后拉取的课程',
        'weekday': 1,
        'start_section': 1,
        'end_section': 2,
        'weeks': [1, 2, 3],
      }
    ]);
    expect(count, 1);
    expect(h.schedule.courses.single.name, '重新连接后拉取的课程');
    final cold = CourseScheduleProvider(h.api, (_) => h.vault(), h.router, h.session)
      ..syncSessionContext(identity.appUserId, identity.studentId);
    addTearDown(cold.dispose);
    await _waitForRestore(cold);
    expect(cold.courses.map((c) => c.name), ['重新连接后拉取的课程']);
  });

  test('真实教务投影在后台配置对账、资料刷新和本机会话过期后保留课表', () async {
    final h = await _ScheduleHarness.create();
    addTearDown(h.close);
    await h.seedSchedule();
    await h.start();
    expect(h.schedule.courses.map((c) => c.name), ['缓存课程']);

    for (var i = 0; i < 3; i++) {
      await h.router.reconcileAccountConfiguration(force: true);
      await h.edu.refreshStatus();
      await h.session.ensureAuthenticated(force: true);
      await h.schedule.loadCachedCoursesIfAvailable();
      expect(h.schedule.courses.map((c) => c.name), ['缓存课程']);
      expect(h.schedule.semesterStart, DateTime(2026, 8, 31));
    }
  });

  test('重新连接同一身份后返回课表，保存的课程和开学日期仍能恢复', () async {
    final h = await _ScheduleHarness.create();
    addTearDown(h.close);
    await h.seedSchedule();
    await h.start();

    await h.session.beginLocalConnection(_ScheduleHarness.identity);
    await h.session.cancelLocalConnection();
    await h.schedule.retryLocalRestore();
    expect(h.schedule.courses.map((c) => c.name), ['缓存课程']);
    expect(h.schedule.semesterStart, DateTime(2026, 8, 31));
  });

  test('返回课表时保存策略再次加载，旧策略就绪不能把已保存课表判为空', () async {
    final h = await _ScheduleHarness.create();
    addTearDown(h.close);
    await h.seedSchedule();
    await h.start();
    final previousPolicy = Completer<void>();
    final currentPolicy = Completer<void>();
    final user = _ScheduleHarness.identity.appUserId;
    AcademicPersistenceRegistry.set(user, enabled: false);
    AcademicPersistenceRegistry.setReadiness(user, previousPolicy.future);

    final returned =
        CourseScheduleProvider(h.api, (_) => h.vault(), h.router, h.session)
          ..syncSessionContext(user, _ScheduleHarness.identity.studentId);
    addTearDown(returned.dispose);
    await Future<void>.delayed(Duration.zero);
    expect(returned.sessionPhase, ScheduleSessionPhase.restoringCache);

    AcademicPersistenceRegistry.setReadiness(user, currentPolicy.future);
    previousPolicy.complete();
    await Future<void>.delayed(Duration.zero);
    final phaseWhilePolicyIsLoading = returned.sessionPhase;
    AcademicPersistenceRegistry.set(user, enabled: true);
    currentPolicy.complete();
    await Future<void>.delayed(Duration.zero);

    expect(phaseWhilePolicyIsLoading, ScheduleSessionPhase.restoringCache,
        reason: '保存许可仍在恢复时不能宣告课表 ready 并显示重新拉取');
    expect(returned.courses.map((c) => c.name), ['缓存课程']);
    expect(returned.semesterStart, DateTime(2026, 8, 31));
  });

  test('学校学期导入后以同年同学期的本地入口恢复，课程不能被当成跨学期清空', () async {
    final h = await _ScheduleHarness.create();
    addTearDown(h.close);
    await h.start();
    final localTerm = CourseTerm.inferCurrentTerm();
    final schoolTerm = localTerm.copyWith(
        id: 'provider_${sha256.convert(utf8.encode('school-term'))}',
        providerTermId: 'school-term');
    await h.schedule.applyFetchedCoursesForTerm(
      term: schoolTerm,
      rawCourses: [
        {
          'course_code': 'COURSE-1',
          'name': '学校导入课程',
          'weekday': 1,
          'start_section': 1,
          'end_section': 2,
          'weeks': [1, 2, 3],
        }
      ],
    );
    expect(h.schedule.courses.map((c) => c.name), ['学校导入课程']);
    await h.schedule.setSemesterStart(DateTime(2026, 8, 31));

    await h.schedule.switchTerm(localTerm);
    expect(h.schedule.courses.map((c) => c.name), ['学校导入课程']);
    expect(h.schedule.currentTerm.providerTermId, 'school-term');
    await h.schedule.retryLocalRestore();
    expect(h.schedule.courses.map((c) => c.name), ['学校导入课程']);

    final otherSemester = localTerm.semester == 3 ? 12 : 3;
    final otherTerm = localTerm.copyWith(
      id: '${localTerm.year}_$otherSemester',
      semester: otherSemester,
    );
    await h.schedule.switchTerm(otherTerm);
    expect(h.schedule.courses, isEmpty);
    expect(await h.schedule.switchTerm(localTerm), isTrue);
    expect(h.schedule.courses.map((c) => c.name), ['学校导入课程']);
    expect(h.schedule.semesterStart, DateTime(2026, 8, 31));
    expect(h.schedule.isSessionReady, isTrue);
    await h.schedule.retryLocalRestore();
    expect(h.schedule.semesterStart, DateTime(2026, 8, 31));
  });

  test('旧缓存没有选中学期时，自动恢复学校学期身份与已保存课表', () async {
    final h = await _ScheduleHarness.create();
    addTearDown(h.close);
    final sourceTermId =
        'provider_${sha256.convert(utf8.encode('school-term'))}';
    await h.seedSchedule(sourceTermId: sourceTermId);
    await h.start();
    expect(h.schedule.courses.map((c) => c.name), ['缓存课程']);
    expect(h.schedule.currentTerm.id, sourceTermId);
    expect(h.schedule.semesterStart, DateTime(2026, 8, 31));
    expect(h.schedule.canMutateSchedule, isTrue);
  });

  test('课程和开学日期并发恢复时保留学校学期身份及磁盘课程', () async {
    final h = await _ScheduleHarness.create();
    addTearDown(h.close);
    final localTerm = CourseTerm.inferCurrentTerm();
    final sourceTermId =
        'provider_${sha256.convert(utf8.encode('school-term'))}';
    await h.seedSchedule(sourceTermId: sourceTermId);
    await h.start();
    await h.schedule.switchTerm(localTerm, loadCache: false);
    await Future.wait([
      h.schedule.loadCachedCoursesIfAvailable(),
      h.schedule.loadSemesterStart(),
    ]);
    expect(h.schedule.currentTerm.id, sourceTermId);
    expect(h.schedule.courses.map((c) => c.name), ['缓存课程']);
    expect(h.schedule.semesterStart, DateTime(2026, 8, 31));
    await h.schedule.retryLocalRestore();
    expect(h.schedule.courses.map((c) => c.name), ['缓存课程']);

    final cold =
        CourseScheduleProvider(h.api, (_) => h.vault(), h.router, h.session)
          ..syncSessionContext(_ScheduleHarness.identity.appUserId,
              _ScheduleHarness.identity.studentId);
    addTearDown(cold.dispose);
    await Future.wait([
      cold.loadCachedCoursesIfAvailable(),
      cold.loadSemesterStart(),
      _waitForRestore(cold),
    ]);
    expect(cold.currentTerm.id, sourceTermId);
    expect(cold.courses.map((c) => c.name), ['缓存课程']);
    expect(cold.semesterStart, DateTime(2026, 8, 31));
  });

  test('学校学期与本地学期入口互换并重建后，自定义课程与调课规则不丢失', () async {
    final h = await _ScheduleHarness.create();
    addTearDown(h.close);
    final localTerm = CourseTerm.inferCurrentTerm();
    final schoolTermId =
        'provider_${sha256.convert(utf8.encode('school-term'))}';
    await h.seedSchedule(sourceTermId: schoolTermId);
    await h.start();
    final course = h.schedule.baseSchedule.single;
    final meeting = course.meetings.single;
    await h.schedule.createChangeRoomOverride(
        courseKey: course.courseKey,
        meetingKey: meeting.meetingKey,
        affectedWeeks: {1},
        toRoom: '调整后的教室',
        sourceSnapshotHash: 'test-hash');
    await h.schedule.addCustomCourse(
        name: '手动课程',
        weekday: 2,
        startSection: 3,
        endSection: 4,
        startWeek: 1,
        endWeek: 3);
    await h.schedule.switchTerm(localTerm);
    expect(h.schedule.overrides, hasLength(1));
    expect(h.schedule.courses.map((c) => c.name), contains('手动课程'));
    expect(h.schedule.courses.any((c) => c.location == '调整后的教室'), isTrue);

    final returned =
        CourseScheduleProvider(h.api, (_) => h.vault(), h.router, h.session)
          ..syncSessionContext(_ScheduleHarness.identity.appUserId,
              _ScheduleHarness.identity.studentId);
    addTearDown(returned.dispose);
    await _waitForRestore(returned);
    expect(returned.currentTerm.id, schoolTermId);
    expect(returned.overrides, hasLength(1));
    expect(returned.courses.map((c) => c.name), contains('手动课程'));
    expect(returned.courses.any((c) => c.location == '调整后的教室'), isTrue);
    expect(returned.semesterStart, DateTime(2026, 8, 31));
  });

  for (final sourceMissing in [true, false]) {
    test('来源快照无法恢复时保留展示和磁盘数据，不把空解析结果覆盖缓存：$sourceMissing', () async {
      final h = await _ScheduleHarness.create();
      addTearDown(h.close);
      await h.seedSchedule(
          sourceTermId: 'different-term', sourceMissing: sourceMissing);
      final before = h.files.values.values.single.toList();
      await h.start();
      expect(h.schedule.courses.map((c) => c.name), ['缓存课程']);
      expect(h.schedule.canMutateSchedule, isFalse);
      expect(h.schedule.errorMessage, contains('重新同步教务'));
      expect(h.files.values.values.single, orderedEquals(before));
    });
  }

  for (final profile in ['light', 'dark', 'large-text']) {
    testWidgets('真实课表页面返回和前台恢复继续显示缓存：$profile', (tester) async {
      await setGoldenViewport(tester, GoldenViewports.phone360x800);
      const channel = MethodChannel('shenliyuan/course_reminders');
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final h = await _ScheduleHarness.create();
      final theme = ThemeProvider(loadOnStart: false);
      addTearDown(h.close);
      addTearDown(theme.dispose);
      await h.seedSchedule(
          sourceTermId:
              'provider_${sha256.convert(utf8.encode('school-term'))}');
      await h.start();
      await h.schedule.setSemesterStart(DateTime.now());
      final captureKey = GlobalKey();
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(
              value: _ScheduleAuth(h.api)),
          ChangeNotifierProvider<EduProvider>.value(value: h.edu),
          ChangeNotifierProvider<CourseScheduleProvider>.value(
              value: h.schedule),
          ChangeNotifierProvider<AcademicSessionController>.value(
              value: h.session),
          ChangeNotifierProvider<ThemeProvider>.value(value: theme),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: profile == 'dark' ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
                textScaler:
                    TextScaler.linear(profile == 'large-text' ? 1.3 : 1)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: captureKey,
            child: ColoredBox(
              color: profile == 'dark'
                  ? AppTheme.darkTheme.scaffoldBackgroundColor
                  : AppTheme.lightTheme.scaffoldBackgroundColor,
              child: const CourseScheduleScreen(),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('缓存课程'), findsOneWidget);
      expect(find.text('还没有课表'), findsNothing);

      unawaited(navigatorKey.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('其他页面')))));
      await tester.pumpAndSettle();
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      final dynamic screen = tester.state(find.byType(CourseScheduleScreen));
      await screen.refreshAfterResumeForTesting();
      await tester.pumpAndSettle();
      expect(find.text('缓存课程'), findsOneWidget);
      expect(find.text('还没有课表'), findsNothing);
      expect(tester.takeException(), isNull);

      const output = String.fromEnvironment('SCHEDULE_QA_OUTPUT');
      if (output.isNotEmpty) {
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$output/$profile.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      h.router.close();
    });
  }
}

class _ScheduleHarness {
  _ScheduleHarness(this.preferences) {
    api.interceptors.add(InterceptorsWrapper(onRequest: (r, handler) {
      handler.resolve(Response(requestOptions: r, statusCode: 200, data: {
        'configs': [
          {
            'provider_id': identity.providerId.value,
            'student_id': identity.studentId,
            'state': 'active',
            'revision': 1,
          }
        ]
      }));
    }));
    final source = _ScheduleSource();
    router = AcademicProviderRouterRepository(
      legacy: AcademicRepositoryImpl(
          local: source, legacy: source, source: AcademicSourceKind.legacy),
      registry: AcademicProviderRegistry([_ScheduleProviderFactory()]),
      configClient: AcademicAccountConfigClient(api),
    );
    session = AcademicSessionController(repository: router);
    edu = EduProvider(api)..setAcademicSessionController(session);
    schedule = CourseScheduleProvider(api, (_) => vault(), router, session);
    edu.addListener(syncSchedule);
  }

  static const identity = AcademicIdentityKey(
      appUserId: '1001',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: 'schedule-student');
  final AppPreferencesStore preferences;
  final api = Dio();
  final secrets = MemoryPersonalSnapshotSecureStore();
  final files = MemoryPersonalSnapshotFileBackend();
  final random = IncrementingRandomBytes();
  late final AcademicProviderRouterRepository router;
  late final AcademicSessionController session;
  late final EduProvider edu;
  late final CourseScheduleProvider schedule;

  static Future<_ScheduleHarness> create() async {
    final h = _ScheduleHarness(await AppPreferencesStore.getInstance());
    await LocalAcademicAccountStore(identity.appUserId, h.preferences)
        .commitIdentity(identity);
    return h;
  }

  AesGcmAccountScopedSnapshotStore vault() => AesGcmAccountScopedSnapshotStore(
        appUserId: identity.appUserId,
        identityNamespace: identity.storageId,
        secureStore: secrets,
        fileBackend: files,
        randomBytes: random.call,
      );

  void syncSchedule() => schedule.syncSessionContext(edu.userId, edu.studentId);

  Future<void> seedSchedule(
      {String? sourceTermId, bool sourceMissing = false}) async {
    AcademicPersistenceRegistry.set(identity.appUserId, enabled: true);
    final cache = ScheduleCacheStore(
      appUserId: identity.appUserId,
      sourceAccountId: identity.studentId,
      identityNamespace: identity.storageId,
      snapshotStore: vault(),
    );
    final term = CourseTerm.inferCurrentTerm();
    final courses = [
      {
        'id': 1,
        'course_code': 'COURSE-1',
        'name': '缓存课程',
        'weekday': 1,
        'start_section': 1,
        'end_section': 2,
        'weeks': [1, 2, 3],
        if (sourceTermId != null) 'course_key': 'edu:$sourceTermId:COURSE-1',
      }
    ];
    if (sourceTermId == null) {
      await cache.writeCourses(
          year: term.year, semester: term.semester, courses: courses);
    } else {
      await cache.writeSourceCourses(
          year: term.year,
          semester: term.semester,
          courses: courses,
          baseCourses: sourceMissing ? [] : courses,
          manualCourses: []);
    }
    await cache.writeSemesterStart(
        year: term.year,
        semester: term.semester,
        semesterStart: DateTime(2026, 8, 31));
  }

  Future<void> start() async {
    edu.syncSessionUser(identity.appUserId);
    await session.syncAppUser(identity.appUserId);
    await edu.ensureStatusLoaded();
    await _waitForRestore(schedule);
  }

  void close() {
    edu.removeListener(syncSchedule);
    schedule.dispose();
    edu.dispose();
    session.dispose();
    router.close();
    api.close();
  }
}

class _ScheduleAuth extends ChangeNotifier implements AuthProvider {
  _ScheduleAuth(this.dio);
  @override
  final Dio dio;
  @override
  User get user => User(
      id: 1001, studentId: '', nickname: '测试用户', createdAt: DateTime(2026));
  @override
  bool get isLoggedIn => true;
  @override
  String get token => 'test-token';
  @override
  int get sessionGeneration => 0;
  @override
  int get accountSessionEpoch => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitForRestore(CourseScheduleProvider schedule) async {
  final ready = Completer<void>();
  void changed() {
    if (!ready.isCompleted &&
        (schedule.isSessionReady ||
            schedule.sessionPhase == ScheduleSessionPhase.restoreFailed)) {
      ready.complete();
    }
  }

  schedule.addListener(changed);
  changed();
  try {
    await ready.future.timeout(const Duration(seconds: 5));
  } finally {
    schedule.removeListener(changed);
  }
}

class _ScheduleProviderFactory implements AcademicProviderFactory {
  @override
  AcademicProviderId get id => AcademicProviderId.syluUndergraduate;
  @override
  AcademicProvider create(AcademicIdentityKey identity) =>
      UndergraduateAcademicProvider(
          identity: identity, source: _ScheduleSource());
}

class _ScheduleSource implements AcademicDataSource {
  @override
  SessionState get sessionState => SessionState.unauthenticated;
  @override
  String? get studentId => null;
  @override
  String get sourceName => '本机测试教务';
  @override
  Future<void> resetSession() async {}
  @override
  Future<void> restoreSession() async {}
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
