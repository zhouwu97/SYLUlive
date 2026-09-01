import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/domain/academic_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_failure.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

void main() {
  group('AcademicSessionController', () {
    test('验证码登录会保留 pending 会话并加载图片', () async {
      final source = _FakeAcademicDataSource(
        loginResult: const CaptchaRequired(),
        captcha: CaptchaChallenge(imageBytes: Uint8List.fromList([1, 2, 3])),
      );
      final controller = _newController(source);

      controller.syncAppUser('app-user-a');
      final result = await controller.login(
        studentId: '2026000001',
        password: 'secret',
      );

      expect(result, isA<CaptchaRequired>());
      expect(controller.isAwaitingCaptcha, isTrue);
      expect(controller.captchaChallenge?.imageBytes, [1, 2, 3]);
      expect(source.lastPassword, 'secret');

      await controller.resetSession();
      controller.dispose();
    });

    test('成功登录后的 Profile、Course、Grade 共享同一数据源', () async {
      final source = _FakeAcademicDataSource(
        loginResult: const LoginSuccess(
          studentId: '2026000001',
          cookieNames: {'JSESSIONID'},
        ),
        profile: const StudentProfile(
          name: '测试同学',
          grade: '2026',
          college: '信息学院',
          major: '软件工程',
        ),
        courses:
            CourseFetchResult(courses: const [], source: CourseSource.desktop),
        grades: GradeFetchResult(grades: const [], pages: 1),
      );
      final controller = _newController(source);

      controller.syncAppUser('app-user-a');
      final login = await controller.login(
        studentId: '2026000001',
        password: 'secret',
      );
      final profile = controller.profile;
      final courses = await controller.loadCourses(year: '2026', semester: 3);
      final grades = await controller.loadGrades(year: '2024', semester: 3);

      expect(login, isA<LoginSuccess>());
      expect(profile?.name, '测试同学');
      expect(courses?.source, CourseSource.desktop);
      expect(grades?.pages, 1);
      expect(source.loginCalls, 1);
      expect(source.profileCalls, 1);
      expect(source.courseCalls, 1);
      expect(source.gradeCalls, 1);

      await controller.resetSession();
      controller.dispose();
    });

    test('切换 App 账号会清除旧教务会话', () async {
      final source = _FakeAcademicDataSource(
        loginResult: const LoginSuccess(
          studentId: '2026000001',
          cookieNames: {'JSESSIONID'},
        ),
      );
      final controller = _newController(source);

      controller.syncAppUser('app-user-a');
      await controller.login(studentId: '2026000001', password: 'secret');
      controller.syncAppUser('app-user-b');
      await controller.resetSession();

      expect(controller.appUserId, 'app-user-b');
      expect(controller.sessionState, SessionState.unauthenticated);
      expect(controller.studentId, isNull);
      expect(source.resetCalls, greaterThanOrEqualTo(2));

      controller.dispose();
    });
  });

  test('本地数据源失败时仓储不会隐式调用旧代理', () async {
    final local = _FakeAcademicDataSource(
      profileError: const ProtocolChangedException(),
    );
    final legacy = _FakeAcademicDataSource(
      profile: const StudentProfile(
        name: '不应被调用',
        grade: '',
        college: '',
        major: '',
      ),
    );
    final repository = AcademicRepositoryImpl(
      local: local,
      legacy: legacy,
    );

    await expectLater(
      repository.getProfile(),
      throwsA(
        isA<AcademicFailure>().having(
          (failure) => failure.kind,
          'kind',
          AcademicFailureKind.protocolChanged,
        ),
      ),
    );
    expect(legacy.profileCalls, 0);

    repository.close();
  });
}

AcademicSessionController _newController(_FakeAcademicDataSource source) {
  return AcademicSessionController(
    repository: AcademicRepositoryImpl(
      local: source,
      legacy: _FakeAcademicDataSource(),
    ),
    cleanupCoordinator: AccountSessionCleanupCoordinator(),
  );
}

final class _FakeAcademicDataSource implements AcademicDataSource {
  _FakeAcademicDataSource({
    this.loginResult = const LoginSuccess(
      studentId: '2026000001',
      cookieNames: {'JSESSIONID'},
    ),
    this.captcha,
    this.profile = const StudentProfile(
      name: '',
      grade: '',
      college: '',
      major: '',
    ),
    CourseFetchResult? courses,
    GradeFetchResult? grades,
    this.profileError,
  })  : courses = courses ??
            CourseFetchResult(courses: const [], source: CourseSource.desktop),
        grades = grades ?? GradeFetchResult(grades: const [], pages: 1);

  final LoginResult loginResult;
  final CaptchaChallenge? captcha;
  final StudentProfile profile;
  final CourseFetchResult courses;
  final GradeFetchResult grades;
  final Object? profileError;

  SessionState _state = SessionState.unauthenticated;
  String? _studentId;
  String? lastPassword;
  int loginCalls = 0;
  int profileCalls = 0;
  int courseCalls = 0;
  int gradeCalls = 0;
  int resetCalls = 0;

  @override
  String get sourceName => 'fake';

  @override
  SessionState get sessionState => _state;

  @override
  String? get studentId => _studentId;

  @override
  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) async {
    loginCalls++;
    lastPassword = password;
    if (loginResult is LoginSuccess) {
      _studentId = (loginResult as LoginSuccess).studentId;
      _state = SessionState.authenticated;
    } else if (loginResult is CaptchaRequired) {
      _studentId = studentId;
      _state = SessionState.awaitingCaptcha;
    }
    return loginResult;
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() async {
    return captcha!;
  }

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) async {
    _state = SessionState.authenticated;
    return const LoginSuccess(
      studentId: '2026000001',
      cookieNames: {'JSESSIONID'},
    );
  }

  @override
  Future<StudentProfile> getProfile() async {
    profileCalls++;
    if (profileError != null) throw profileError!;
    return profile;
  }

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) async {
    courseCalls++;
    return courses;
  }

  @override
  Future<GradeFetchResult> getGrades({
    required String year,
    required int semester,
  }) async {
    gradeCalls++;
    return grades;
  }

  @override
  Future<void> resetSession() async {
    resetCalls++;
    _state = SessionState.unauthenticated;
    _studentId = null;
  }

  @override
  void close() {}
}
