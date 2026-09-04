import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/schedule_cache_store.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

import 'helpers/personal_snapshot_test_fakes.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryPersonalSnapshotSecureStore secureStore;
  late MemoryPersonalSnapshotFileBackend files;
  late IncrementingRandomBytes random;

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    secureStore = MemoryPersonalSnapshotSecureStore();
    files = MemoryPersonalSnapshotFileBackend();
    random = IncrementingRandomBytes();
  });

  AccountScopedSnapshotStore createSnapshotStore(String appUserId) {
    return AesGcmAccountScopedSnapshotStore(
      appUserId: appUserId,
      secureStore: secureStore,
      fileBackend: files,
      randomBytes: random.call,
    );
  }

  CourseScheduleProvider createProvider([Dio? dio]) {
    return CourseScheduleProvider(dio, createSnapshotStore);
  }

  test('onlyCache load ends immediately when no course cache exists', () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');

    await provider.loadCourses(onlyCache: true);

    expect(provider.isLoading, isFalse);
    expect(provider.courses, isEmpty);
    expect(provider.gridData, isEmpty);
  });

  test('来源账号延迟恢复后自动进入 ready 并读取对应会话缓存', () async {
    final seed = createProvider()..syncSessionContext('1001', '2403130233');
    await seed.applyFetchedCourses([
      {
        'name': '线性代数',
        'time': 1,
        'end_time': 2,
        'week_day': 2,
        'weeks': [1, 2, 3],
      },
    ]);

    final provider = createProvider()..syncSessionContext('1001', '');
    expect(provider.sessionPhase, ScheduleSessionPhase.resolvingIdentity);
    expect(provider.isSessionReady, isFalse);

    final generationBeforeSource = provider.contextGeneration;
    provider.syncSessionContext('1001', '2403130233');
    expect(provider.contextGeneration, greaterThan(generationBeforeSource));
    expect(provider.sessionKey, '1001::2403130233');

    for (var i = 0; i < 20 && !provider.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(provider.isSessionReady, isTrue);
    expect(provider.sessionPhase, ScheduleSessionPhase.ready);
    expect(provider.courses, hasLength(1));
    expect(provider.courses.single.name, '线性代数');
  });

  test(
      'fetched courses are available from cache for the same user and semester',
      () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');

    await provider.applyFetchedCourses([
      {
        'name': '高等数学',
        'teacher': '王老师',
        'location': 'A101',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': [1, 2, 3],
      },
    ]);

    final reloaded = createProvider()..syncSessionContext('1001', '2403130233');
    final loaded = await reloaded.loadCachedCoursesIfAvailable();

    expect(loaded, isTrue);
    expect(reloaded.isLoading, isFalse);
    expect(reloaded.courses, hasLength(1));
    expect(reloaded.courses.single.name, '高等数学');
  });

  test('来源学号变化后不读取旧课表缓存', () async {
    final provider = createProvider()..syncSessionContext('1001', '2403130233');
    await provider.applyFetchedCourses(<Map<String, dynamic>>[
      <String, dynamic>{
        'name': '数据结构',
        'time': 1,
        'end_time': 2,
        'week_day': 1,
        'weeks': <int>[1, 2],
      },
    ]);

    final changedSource = createProvider()
      ..syncSessionContext('1001', '2403130234');
    final loaded = await changedSource.loadCachedCoursesIfAvailable();

    expect(loaded, isFalse);
    expect(changedSource.courses, isEmpty);
  });

  test('延迟课表响应在换号后不会写入新账号或恢复旧界面', () async {
    final courseStarted = Completer<void>();
    final releaseResponse = Completer<void>();
    final repository = _FakeCourseRepository(
      courseStarted: courseStarted,
      courseGate: releaseResponse,
      courses: CourseFetchResult(
        source: CourseSource.mobile,
        courses: [
          const RawCourse(
            name: '旧账号课程',
            teacher: '测试老师',
            location: 'A101',
            section: '1-2节',
            weekDay: '1',
            weekExpression: '1周',
          ),
        ],
      ),
    );
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('1001');
    await controller.login(studentId: '2403130233', password: 'secret');
    final provider = CourseScheduleProvider(
      Dio(),
      createSnapshotStore,
      repository,
      controller,
    )..syncSessionContext('1001', '2403130233');

    final pending = provider.loadCourses(forceRefresh: true);
    await courseStarted.future;
    provider.syncSessionContext('2002', '2403130234');
    releaseResponse.complete();
    await pending;

    expect(provider.courses, isEmpty);
    final oldStore = ScheduleCacheStore(
      appUserId: '1001',
      sourceAccountId: '2403130233',
      snapshotStore: createSnapshotStore('1001'),
    );
    final newStore = ScheduleCacheStore(
      appUserId: '2002',
      sourceAccountId: '2403130234',
      snapshotStore: createSnapshotStore('2002'),
    );
    expect(await oldStore.readTerm(year: '2025', semester: 12), isNull);
    expect(await newStore.readTerm(year: '2025', semester: 12), isNull);
    for (var i = 0; i < 20 && !provider.isSessionReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    provider.dispose();
    controller.dispose();
  });

  test('课程获取成功但保险箱写入失败时明确提示未持久化', () async {
    final repository = _FakeCourseRepository(
      courses: CourseFetchResult(
        source: CourseSource.mobile,
        courses: [
          const RawCourse(
            name: '数据结构',
            teacher: '测试老师',
            location: 'A101',
            section: '1-2节',
            weekDay: '1',
            weekExpression: '1-2周',
          ),
        ],
      ),
    );
    files.failWrites = true;
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('1001');
    await controller.login(studentId: '2403130233', password: 'secret');
    final provider = CourseScheduleProvider(
      Dio(),
      createSnapshotStore,
      repository,
      controller,
    )..syncSessionContext('1001', '2403130233');

    await provider.loadCourses(forceRefresh: true);

    expect(provider.courses.single.name, '数据结构');
    expect(provider.errorMessage, '课程已获取，但未能安全保存，请稍后重试');
    expect(provider.isLoading, isFalse);
    provider.dispose();
    controller.dispose();
  });
}

final class _FakeCourseRepository implements AcademicRepository {
  _FakeCourseRepository({
    required this.courses,
    this.courseStarted,
    this.courseGate,
  });

  final CourseFetchResult courses;
  final Completer<void>? courseStarted;
  final Completer<void>? courseGate;
  SessionState _state = SessionState.unauthenticated;
  String? _studentId;

  @override
  AcademicSourceKind get sourceKind => AcademicSourceKind.local;

  @override
  AcademicCapabilities get capabilities => const AcademicCapabilities.local();

  @override
  SessionState get sessionState => _state;

  @override
  String? get studentId => _studentId;

  @override
  String get sourceName => '测试本机直连';

  @override
  Future<void> switchSource(AcademicSourceKind source) async {}

  @override
  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) async {
    _studentId = studentId;
    _state = SessionState.authenticated;
    return LoginSuccess(studentId: studentId, cookieNames: const {'test'});
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() async {
    throw const ProtocolChangedException(message: '测试未配置验证码');
  }

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) async {
    return LoginSuccess(
      studentId: _studentId ?? '2403130233',
      cookieNames: const {'test'},
    );
  }

  @override
  Future<StudentProfile> getProfile() async => const StudentProfile(
        name: '测试同学',
        grade: '2026',
        college: '信息学院',
        major: '软件工程',
      );

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) async {
    courseStarted?.complete();
    if (courseGate != null) await courseGate!.future;
    return courses;
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) async =>
      GradeFetchResult(grades: const [], pages: 1);

  @override
  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) async {
    throw UnimplementedError('测试未实现成绩详情');
  }

  @override
  Future<AcademicSituation> getAcademicSituation() async {
    throw UnimplementedError('测试未实现学业情况');
  }

  @override
  Future<CreditRequirement> getCreditRequirements() async {
    throw UnimplementedError('测试未实现学分要求');
  }

  @override
  Future<void> resetSession() async {
    _state = SessionState.unauthenticated;
    _studentId = null;
  }

  @override
  void close() {}
}
