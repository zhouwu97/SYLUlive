import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/data/datasource/legacy_server_data_source.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';
import 'package:shenliyuan/models/edu_grade.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  test('本机模式下未迁移能力不会读取旧缓存或请求旧代理', () async {
    final repository = _FakeAcademicRepository();
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');
    await controller.login(studentId: '2026000001', password: 'secret');

    final requestedPaths = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestedPaths.add(options.path);
            handler.reject(
              DioException(requestOptions: options),
            );
          },
        ),
      );
    final provider = EduProvider(dio)
      ..setAcademicSessionController(controller)
      ..syncSessionUser('app-user-a');
    const grade = EduGrade(
      name: '数据结构',
      classId: 'class-a',
      displayGrade: '88',
      credits: 3,
      gpa: 3.7,
      isDegree: true,
    );

    final detail = await provider.fetchGradeDetail(grade, '2025', 12);
    final situation = await provider.fetchAcademicSituation();
    final requirements = await provider.fetchCreditRequirements();
    await provider.prefetchGradeDetails(
      const <EduGrade>[grade],
      '2025',
      12,
      initialDelay: Duration.zero,
    );

    expect(provider.isUsingLocalAcademicSession, isTrue);
    expect(detail.errorCode, 'LOCAL_FEATURE_NOT_SUPPORTED');
    expect(situation.errorCode, 'LOCAL_FEATURE_NOT_SUPPORTED');
    expect(requirements.errorCode, 'LOCAL_FEATURE_NOT_SUPPORTED');
    expect(provider.getCachedGradeDetail(grade, '2025', 12), isNull);
    expect(provider.getCachedAcademicSituation(), isNull);
    expect(provider.getCachedCreditRequirements(), isNull);
    expect(requestedPaths, isEmpty);

    controller.dispose();
  });

  test('本机来源尚未登录时不会回退到旧服务端课表接口', () async {
    final repository = _FakeAcademicRepository();
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');

    final requestedPaths = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestedPaths.add(options.path);
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );
    final provider = EduProvider(dio)
      ..setAcademicSessionController(controller)
      ..syncSessionUser('app-user-a');

    final result = await provider.getCourses('2026', 3);

    expect(provider.isUsingLocalAcademicSession, isTrue);
    expect(result?.success, isFalse);
    expect(result?.errorMessage, '教务账号未就绪');
    expect(requestedPaths, isEmpty);

    provider.dispose();
    controller.dispose();
  });

  test('生产兼容数据源禁网时不会触碰教务服务器', () async {
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
    final source = LegacyServerDataSource(dio, networkEnabled: false);

    await expectLater(
      source.login(studentId: '2026000001', password: 'secret'),
      throwsA(
        isA<NetworkException>().having(
          (error) => error.code,
          'code',
          'LEGACY_SERVER_BLOCKED',
        ),
      ),
    );
    await source.resetSession();

    expect(requestedPaths, isEmpty);
  });

  test('课表网格的本机来源尚未登录时不会请求旧服务端接口', () async {
    final repository = _FakeAcademicRepository();
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');

    final requestedPaths = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestedPaths.add(options.path);
            handler.reject(DioException(requestOptions: options));
          },
        ),
      );
    final schedule = CourseScheduleProvider(
      dio,
      (_) => _NoopSnapshotStore('app-user-a'),
      repository,
      controller,
    )..syncSessionContext('app-user-a', '2026000001');

    await schedule.loadCourses(forceRefresh: true);

    expect(requestedPaths, isEmpty);
    expect(schedule.errorMessage, isNotNull);

    schedule.dispose();
    controller.dispose();
  });

  test('课表本机请求经 SessionController 排队，不与登录并发', () async {
    final loginRelease = Completer<void>();
    final repository = _FakeAcademicRepository(
      loginGate: loginRelease.future,
    );
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');

    final loginFuture = controller.login(
      studentId: '2026000001',
      password: 'secret',
    );
    await repository.loginStarted.future;

    final schedule = CourseScheduleProvider(
      Dio(),
      (_) => _NoopSnapshotStore('app-user-a'),
      repository,
      controller,
    )..syncSessionContext('app-user-a', '2026000001');

    final coursesFuture = schedule.loadCourses(forceRefresh: true);
    expect(repository.courseCalls, 0);

    loginRelease.complete();
    await loginFuture;
    await coursesFuture;

    expect(repository.courseCalls, 1);
    expect(repository.calls.indexOf('login:start'),
        lessThan(repository.calls.indexOf('courses')));
    expect(schedule.courses.single.name, '本机课程');

    controller.dispose();
    schedule.dispose();
  });

  test('本机 RawGrade 映射正确且切换旧来源不会回退', () async {
    final repository = _FakeAcademicRepository(
      grades: GradeFetchResult(
        grades: <RawGrade>[
          RawGrade(
            raw: <String, Object?>{
              'kcmc': '本机高等数学',
              'jxb_id': 'LOCAL-JXB',
              'kch_id': 'LOCAL-KC',
              'kch': 'LOCAL101',
              'xh_id': 'LOCAL-XH',
              'jsxm': '本机张老师',
              'sfxwkc': '是',
              'xf': '4',
              'jd': '3.8',
              'xfjd': '15.2',
              'bfzcj': '88',
              'cj': '88',
            },
          ),
        ],
        pages: 1,
      ),
    );
    final requestedPaths = <String>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestedPaths.add(options.path);
            if (options.path == '/edu/status') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{
                    'edu_authorized': true,
                    'edu_student_id': 'legacy-x',
                  },
                ),
              );
              return;
            }
            if (options.path == '/edu/grades') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{
                    'grades': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'name': '旧代理课程',
                        'grade': '77',
                        'credits': 2,
                        'gpa': 2.7,
                        'is_degree': false,
                      },
                    ],
                  },
                ),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    final provider = EduProvider(
      dio,
      (_) => _NoopSnapshotStore('app-user-a'),
    )
      ..setAcademicSessionController(controller)
      ..syncSessionUser('app-user-a');

    await provider.ensureStatusLoaded();
    await controller.syncAppUser('app-user-a');
    await controller.login(studentId: 'local-y', password: 'secret');

    final localResult = await provider.fetchGrades('2024', 3);
    expect(localResult.success, isTrue);
    final localGrade = localResult.data!.single;
    expect(localGrade.name, '本机高等数学');
    expect(localGrade.classId, 'LOCAL-JXB');
    expect(localGrade.displayGrade, '88');
    expect(localGrade.credits, 4);
    expect(localGrade.gpa, 3.8);
    expect(localGrade.teacher, '本机张老师');
    expect(localGrade.isDegree, isTrue);

    expect(provider.getCachedGrades('2024', 3)!.grades.single.name, '本机高等数学');

    repository.currentSource = AcademicSourceKind.legacy;
    await controller.resetSession();
    await provider.refreshStatus();
    expect(provider.isUsingLocalAcademicSession, isFalse);
    expect(provider.studentId, isEmpty);
    expect(provider.getCachedGrades('2024', 3), isNull);

    final legacyResult = await provider.fetchGrades('2024', 3);
    expect(legacyResult.success, isFalse);
    expect(legacyResult.errorCode, 'LOCAL_SESSION_NOT_READY');
    expect(requestedPaths, isEmpty);

    repository.currentSource = AcademicSourceKind.local;
    await controller.login(studentId: 'local-y', password: 'secret');
    expect(provider.getCachedGrades('2024', 3)!.grades.single.name, '本机高等数学');

    provider.dispose();
    controller.dispose();
  });

  test('旧代理课表缺少星期或节次时 fail-closed', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/edu/bind') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{
                    'success': true,
                    'user': <String, dynamic>{
                      'edu_authorized': true,
                      'edu_student_id': '2026000001',
                    },
                  },
                ),
              );
              return;
            }
            if (options.path == '/edu/courses') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: const <String, dynamic>{
                    'success': true,
                    'courses': <Map<String, dynamic>>[
                      <String, dynamic>{'name': '字段不完整'},
                    ],
                  },
                ),
              );
              return;
            }
            handler.next(options);
          },
        ),
      );
    final source = LegacyServerDataSource(dio, networkEnabled: true);

    expect(
      await source.login(studentId: '2026000001', password: 'secret'),
      isA<LoginSuccess>(),
    );
    await expectLater(
      source.getCourses(year: '2026', semester: 3),
      throwsA(
        isA<ProtocolChangedException>().having(
          (error) => error.message,
          'message',
          '旧课表记录缺少开始节次',
        ),
      ),
    );
  });

  test('本机 RawCourse 缺少节次时不会伪造成第 1 节', () async {
    final repository = _FakeAcademicRepository(
      courses: CourseFetchResult(
        courses: <RawCourse>[
          const RawCourse(
            name: '不完整课程',
            teacher: '测试老师',
            location: 'A101',
            section: '',
            weekDay: '3',
            weekExpression: '1-16周',
          ),
        ],
        source: CourseSource.mobile,
      ),
    );
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');
    await controller.login(studentId: '2026000001', password: 'secret');
    final schedule = CourseScheduleProvider(
      Dio(),
      (_) => _NoopSnapshotStore('app-user-a'),
      repository,
      controller,
    )..syncSessionContext('app-user-a', '2026000001');

    await schedule.loadCourses(forceRefresh: true);

    expect(schedule.courses, isEmpty);
    expect(schedule.errorMessage, '解析课表数据失败');

    controller.dispose();
    schedule.dispose();
  });

  test('EduProvider legacy 兼容课表支持单节并保留真实星期', () async {
    final repository = _FakeAcademicRepository(
      courses: CourseFetchResult(
        courses: <RawCourse>[
          const RawCourse(
            name: '单节课程',
            teacher: '测试老师',
            location: 'B202',
            section: '3节',
            weekDay: '2',
            weekExpression: '1-16周',
          ),
        ],
        source: CourseSource.mobile,
      ),
    );
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');
    await controller.login(studentId: '2026000001', password: 'secret');
    final provider = EduProvider(Dio())
      ..setAcademicSessionController(controller)
      ..syncSessionUser('app-user-a');

    final result = await provider.getCourses('2026', 3);
    final course = result!.data!.single;
    expect(course['start_section'], 3);
    expect(course['end_section'], 3);
    expect(course['weekday'], 2);

    provider.dispose();
    controller.dispose();
  });

  test('EduProvider legacy 兼容课表缺少节次时 fail-closed', () async {
    final repository = _FakeAcademicRepository(
      courses: CourseFetchResult(
        courses: <RawCourse>[
          const RawCourse(
            name: '缺少节次',
            teacher: '测试老师',
            location: 'B202',
            section: '',
            weekDay: '2',
            weekExpression: '1-16周',
          ),
        ],
        source: CourseSource.mobile,
      ),
    );
    final controller = AcademicSessionController(
      repository: repository,
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');
    await controller.login(studentId: '2026000001', password: 'secret');
    final provider = EduProvider(Dio())
      ..setAcademicSessionController(controller)
      ..syncSessionUser('app-user-a');

    await expectLater(
      provider.getCourses('2026', 3),
      throwsA(
        isA<ProtocolChangedException>().having(
          (error) => error.message,
          'message',
          '本机课表记录缺少有效节次',
        ),
      ),
    );

    provider.dispose();
    controller.dispose();
  });
}

final class _FakeAcademicRepository implements AcademicRepository {
  _FakeAcademicRepository({
    this.loginGate,
    CourseFetchResult? courses,
    GradeFetchResult? grades,
  })  : courses = courses ??
            CourseFetchResult(
              courses: <RawCourse>[
                const RawCourse(
                  name: '本机课程',
                  teacher: '测试老师',
                  location: 'A101',
                  section: '1-2节',
                  weekDay: '1',
                  weekExpression: '1周',
                ),
              ],
              source: CourseSource.mobile,
            ),
        grades = grades ?? GradeFetchResult(grades: const [], pages: 1);

  final Future<void>? loginGate;
  final CourseFetchResult courses;
  final GradeFetchResult grades;
  final Completer<void> loginStarted = Completer<void>();
  final List<String> calls = [];
  SessionState _state = SessionState.unauthenticated;
  String? _studentId;
  int courseCalls = 0;
  AcademicSourceKind currentSource = AcademicSourceKind.local;

  @override
  AcademicSourceKind get sourceKind => currentSource;

  @override
  AcademicCapabilities get capabilities =>
      currentSource == AcademicSourceKind.local
          ? const AcademicCapabilities.local()
          : const AcademicCapabilities.legacy();

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
    calls.add('login:start');
    if (!loginStarted.isCompleted) loginStarted.complete();
    if (loginGate != null) await loginGate!;
    _studentId = studentId;
    _state = SessionState.authenticated;
    calls.add('login:end');
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
      studentId: _studentId ?? '2026000001',
      cookieNames: const {'test'},
    );
  }

  @override
  Future<StudentProfile> getProfile() async {
    calls.add('profile');
    return const StudentProfile(
      name: '测试同学',
      grade: '2026',
      college: '信息学院',
      major: '软件工程',
    );
  }

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) async {
    courseCalls++;
    calls.add('courses');
    return courses;
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) async {
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
    calls.add('reset');
    _state = SessionState.unauthenticated;
    _studentId = null;
  }

  @override
  void close() {}
}

final class _NoopSnapshotStore implements AccountScopedSnapshotStore {
  _NoopSnapshotStore(this.accountFingerprint);

  @override
  final String accountFingerprint;

  @override
  Future<void> clearUser() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteType(PersonalDataType type) async {}

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
