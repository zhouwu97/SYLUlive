import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/storage/academic_storage_preferences.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/academic_cache_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/models/edu_grade.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

import '../helpers/personal_snapshot_test_fakes.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureStore = <String, String>{};
  late MemoryPersonalSnapshotSecureStore vaultSecureStore;
  late MemoryPersonalSnapshotFileBackend vaultFiles;
  late IncrementingRandomBytes vaultRandom;

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
    secureStore.clear();
    vaultSecureStore = MemoryPersonalSnapshotSecureStore();
    vaultFiles = MemoryPersonalSnapshotFileBackend();
    vaultRandom = IncrementingRandomBytes();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secureStore[key];
        case 'write':
          secureStore[key!] = args['value'] as String;
          return null;
        case 'delete':
          secureStore.remove(key);
          return null;
        case 'deleteAll':
          secureStore.clear();
          return null;
        case 'containsKey':
          return secureStore.containsKey(key);
        case 'readAll':
          return secureStore;
      }
      return null;
    });
  });

  AccountScopedSnapshotStore createSnapshotStore(String appUserId) {
    return AesGcmAccountScopedSnapshotStore(
      appUserId: appUserId,
      secureStore: vaultSecureStore,
      fileBackend: vaultFiles,
      randomBytes: vaultRandom.call,
    );
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  Future<_EduFixture> createFixture({
    GradeFetchResult? grades,
    CourseFetchResult? courses,
    Completer<void>? gradeGate,
    Completer<void>? courseGate,
    Object? gradeError,
  }) async {
    final repository = _FakeAcademicRepository(
      grades: grades,
      courses: courses,
      gradeGate: gradeGate,
      courseGate: courseGate,
      gradeError: gradeError,
    );
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    final provider = EduProvider(Dio(), createSnapshotStore)
      ..setAcademicSessionController(controller);
    await controller.syncAppUser('app-user-a');
    await controller.login(studentId: '2403130233', password: 'secret');
    final preferences = AcademicStoragePreferences(
      appUserId: 'app-user-a',
      store: await AppPreferencesStore.getInstance(),
    );
    await preferences.setSaveAcademicData(true);
    await preferences.markMigrated();
    provider.setUserId('app-user-a');
    await provider.ensureStatusLoaded();
    return _EduFixture(provider, controller, repository);
  }

  group('EduProvider 本机教务契约', () {
    test('没有本机会话控制器时不会回退到旧服务端教务接口', () async {
      final requestedPaths = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requestedPaths.add(options.path);
              handler.next(options);
            },
          ),
        );
      final provider = EduProvider(dio, createSnapshotStore)
        ..setUserId('app-user-a');
      await provider.ensureStatusLoaded();

      final result = await provider.fetchGrades('2025', 3);

      expect(result.success, isFalse);
      expect(result.errorCode, 'LOCAL_SESSION_NOT_READY');
      expect(requestedPaths, isEmpty);
      provider.dispose();
    });

    test('本机成绩会转换为应用模型并写入账号隔离缓存', () async {
      final fixture = await createFixture(
        grades: GradeFetchResult(
          pages: 1,
          grades: [
            RawGrade(
              raw: {
                'kcmc': '数字逻辑',
                'cj': '64.7',
                'xf': 3.0,
                'jd': 1.47,
                'sfxwkc': '是',
              },
            ),
            RawGrade(
              raw: {
                'kcmc': '体育4',
                'cj': '84',
                'xf': 1,
                'jd': 3.4,
                'sfxwkc': '否',
              },
            ),
          ],
        ),
      );

      final result = await fixture.provider.fetchGrades('2025', 12);

      expect(result.success, isTrue);
      expect(result.data, hasLength(2));
      expect(result.data![0].name, '数字逻辑');
      expect(result.data![0].displayGrade, '64.7');
      expect(result.data![0].credits, 3.0);
      expect(result.data![0].gpa, 1.47);
      expect(result.data![0].isDegree, isTrue);
      expect(result.data![1].isPassed, isTrue);
      expect(fixture.provider.getCachedGrades('2025', 12), isNotNull);

      fixture.dispose();
    });

    test('本机空成绩仍是成功响应', () async {
      final fixture = await createFixture(
        grades: GradeFetchResult(grades: const [], pages: 1),
      );

      final result = await fixture.provider.fetchGrades('2025', 3);

      expect(result.success, isTrue);
      expect(result.data, isEmpty);
      fixture.dispose();
    });

    test('成绩请求期间切换 App 账号会丢弃旧账号结果', () async {
      final gradeGate = Completer<void>();
      final gradeStarted = Completer<void>();
      final fixture = await createFixture(gradeGate: gradeGate);
      fixture.repository.gradeStarted = gradeStarted;

      final pending = fixture.provider.fetchGrades('2025', 3);
      await gradeStarted.future;
      fixture.provider.setUserId('app-user-b');
      gradeGate.complete();

      final result = await pending;

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('用户已切换'));
      expect(fixture.provider.getCachedGrades('2025', 3), isNull);
      fixture.dispose();
    });

    test('本机课表会映射为旧页面兼容字段', () async {
      final fixture = await createFixture(
        courses: CourseFetchResult(
          source: CourseSource.mobile,
          courses: const [
            RawCourse(
              name: '数据结构',
              teacher: '张老师',
              location: 'A101',
              section: '3-4节',
              weekDay: '2',
              weekExpression: '1-16周',
            ),
          ],
        ),
      );

      final result = await fixture.provider.getCourses('2025', 3);

      expect(result?.success, isTrue);
      expect(result?.data?.single['name'], '数据结构');
      expect(result?.data?.single['weekday'], 2);
      expect(result?.data?.single['start_section'], 3);
      expect(result?.data?.single['end_section'], 4);
      expect(
        result?.data?.single['weeks'],
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
      );
      fixture.dispose();
    });

    test('本机教务详情类能力走本机 Session 且不访问 Dio', () async {
      final requestedPaths = <String>[];
      final fixture = await createFixture();
      fixture.provider.dispose();
      final guardedProvider = EduProvider(
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                requestedPaths.add(options.path);
                handler.next(options);
              },
            ),
          ),
        createSnapshotStore,
      )
        ..setAcademicSessionController(fixture.controller)
        ..setUserId('app-user-a');
      const grade = EduGrade(
        name: '数据结构',
        classId: 'class-a',
        displayGrade: '88',
        credits: 3,
        gpa: 3.7,
        isDegree: true,
      );

      fixture.repository.gradeDetail = GradeDetail(
        success: true,
        courseName: '数据结构',
        totalGrade: '88',
        components: const [],
      );
      fixture.repository.academicSituation = const AcademicSituation(
        success: true,
        allGpa: 3.7,
        degreeGpa: 3.6,
        totalCourses: 1,
        passedCourses: 1,
        failedCourses: 0,
        notStartedCourses: 0,
        inProgressCourses: 0,
        degreeTotalCourses: 1,
        degreePassedCourses: 1,
        degreeFailedCourses: 0,
        degreeNotStartedCourses: 0,
        degreeInProgressCourses: 0,
        courses: const [],
        coursesStatus: 'complete',
      );
      fixture.repository.creditRequirements = const CreditRequirement(
        success: true,
        status: 'complete',
        modules: [],
        improvementCourses: [],
      );

      final detail = await guardedProvider.fetchGradeDetail(grade, '2025', 3);
      final situation = await guardedProvider.fetchAcademicSituation();
      final requirements = await guardedProvider.fetchCreditRequirements();
      await guardedProvider.prefetchGradeDetails(
        const [grade],
        '2025',
        3,
        initialDelay: Duration.zero,
      );

      expect(detail.success, isTrue);
      expect(situation.success, isTrue);
      expect(requirements.success, isTrue);
      expect(guardedProvider.getCachedGradeDetail(grade, '2025', 3), isNotNull);
      expect(requestedPaths, isEmpty);
      guardedProvider.dispose();
      fixture.controller.dispose();
    });

    test('清除本机教务会话会同时清理内存和加密成绩快照', () async {
      final fixture = await createFixture(
        grades: GradeFetchResult(
          grades: [
            RawGrade(
              raw: {
                'kcmc': '数据结构',
                'cj': '90',
                'xf': 4,
                'jd': 4.0,
                'sfxwkc': '是',
              },
            ),
          ],
          pages: 1,
        ),
      );
      await fixture.provider.fetchGrades('2025', 3);
      final store = AcademicCacheStore(
        appUserId: 'app-user-a',
        sourceAccountId: '2403130233',
        snapshotStore: createSnapshotStore('app-user-a'),
      );
      expect(await store.readSnapshot(), isNotNull);

      await fixture.provider.clearLocalSession();

      expect(fixture.provider.userId, isNull);
      expect(fixture.provider.isBound, isFalse);
      expect(fixture.provider.getCachedGrades('2025', 3), isNull);
      expect(await store.readSnapshot(), isNull);
      fixture.dispose();
    });

    test('加密缓存清理失败时仍撤销本地教务绑定标记', () async {
      final repository = _FakeAcademicRepository();
      final controller = AcademicSessionController(
        repository: repository,
        cleanupCoordinator: AccountSessionCleanupCoordinator(),
      );
      final failingStore = _FailingClearSnapshotStore();
      final provider = EduProvider(
        Dio(),
        (_) => failingStore,
      )..setAcademicSessionController(controller);
      await controller.syncAppUser('app-user-a');
      await controller.login(studentId: '2403130233', password: 'secret');
      provider.setUserId('app-user-a');
      await provider.ensureStatusLoaded();
      final prefs = await AppPreferencesStore.getInstance();
      await prefs.setBool('edu_bound_app-user-a', true);

      await provider.clearLocalSession();

      expect(provider.isBound, isFalse);
      expect(prefs.getBool('edu_bound_app-user-a'), isNull);
      expect(provider.errorMessage, contains('缓存清理'));
      provider.dispose();
      controller.dispose();
    });

    test('本机成绩错误不会写入缓存', () async {
      final fixture = await createFixture(
        gradeError: const NetworkException(message: '教务系统暂时不可用'),
      );

      final result = await fixture.provider.fetchGrades('2025', 3);

      expect(result.success, isFalse);
      expect(result.errorMessage, isNotEmpty);
      expect(fixture.provider.getCachedGrades('2025', 3), isNull);
      fixture.dispose();
    });
  });
}

final class _EduFixture {
  _EduFixture(this.provider, this.controller, this.repository);

  final EduProvider provider;
  final AcademicSessionController controller;
  final _FakeAcademicRepository repository;

  void dispose() {
    provider.dispose();
    controller.dispose();
  }
}

final class _FailingClearSnapshotStore implements AccountScopedSnapshotStore {
  @override
  String get accountFingerprint => 'failing-clear-account';

  @override
  Future<void> clearUser() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteType(PersonalDataType type) async {
    throw StateError('模拟保险箱删除失败');
  }

  @override
  Future<PersonalSnapshot?> read({
    required PersonalDataType type,
    required String sourceSystem,
    required String sourceAccountId,
  }) async =>
      null;

  @override
  Future<void> write({
    required PersonalDataType type,
    required int schemaVersion,
    required String sourceSystem,
    required String sourceAccountId,
    required Map<String, dynamic> payload,
    DateTime? fetchedAt,
    DateTime? expiresAt,
  }) async {}
}

final class _FakeAcademicRepository implements AcademicRepository {
  _FakeAcademicRepository({
    GradeFetchResult? grades,
    CourseFetchResult? courses,
    this.gradeGate,
    this.courseGate,
    this.gradeError,
  })  : grades = grades ?? GradeFetchResult(grades: const [], pages: 1),
        courses = courses ??
            CourseFetchResult(courses: const [], source: CourseSource.mobile);

  GradeFetchResult grades;
  CourseFetchResult courses;
  final Completer<void>? gradeGate;
  final Completer<void>? courseGate;
  final Object? gradeError;
  GradeDetail? gradeDetail;
  AcademicSituation? academicSituation;
  CreditRequirement? creditRequirements;
  Completer<void>? gradeStarted;
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
    _state = SessionState.authenticated;
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
    if (courseGate != null) await courseGate!.future;
    return courses;
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) async {
    gradeStarted?.complete();
    if (gradeGate != null) await gradeGate!.future;
    if (gradeError != null) throw gradeError!;
    return grades;
  }

  @override
  Future<GradeDetail> getGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) async {
    final value = gradeDetail;
    if (value == null) throw UnimplementedError('测试未实现成绩详情');
    return value;
  }

  @override
  Future<AcademicSituation> getAcademicSituation() async {
    final value = academicSituation;
    if (value == null) throw UnimplementedError('测试未实现学业情况');
    return value;
  }

  @override
  Future<CreditRequirement> getCreditRequirements() async {
    final value = creditRequirements;
    if (value == null) throw UnimplementedError('测试未实现学分要求');
    return value;
  }

  @override
  Future<void> resetSession() async {
    _state = SessionState.unauthenticated;
    _studentId = null;
  }

  @override
  void close() {}
}
