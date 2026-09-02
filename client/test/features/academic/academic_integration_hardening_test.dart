import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/data/datasource/legacy_server_data_source.dart';
import 'package:shenliyuan/features/campus_data/storage/account_scoped_snapshot_store.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/providers/course_schedule_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';
import 'package:shenliyuan/models/edu_grade.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final source = LegacyServerDataSource(dio);

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
}

final class _FakeAcademicRepository implements AcademicRepository {
  _FakeAcademicRepository({this.loginGate});

  final Future<void>? loginGate;
  final Completer<void> loginStarted = Completer<void>();
  final List<String> calls = [];
  SessionState _state = SessionState.unauthenticated;
  String? _studentId;
  int courseCalls = 0;

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
    return CourseFetchResult(
      courses: <RawCourse>[
        RawCourse(
          name: '本机课程',
          teacher: '测试老师',
          location: 'A101',
          section: '1-2节',
          weekDay: '1',
          weekExpression: '1周',
        ),
      ],
      source: CourseSource.mobile,
    );
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) async {
    return GradeFetchResult(grades: <RawGrade>[], pages: 1);
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
