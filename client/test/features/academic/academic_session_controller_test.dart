import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/application/academic_login_coordinator.dart';
import 'package:shenliyuan/features/academic/domain/academic_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_failure.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/presentation/academic_login_dialog.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_policy.dart';
import 'package:shenliyuan/features/academic/storage/academic_storage_preferences.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

void main() {
  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

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
      await controller.syncAppUser('app-user-b');

      expect(controller.appUserId, 'app-user-b');
      expect(controller.sessionState, SessionState.unauthenticated);
      expect(controller.studentId, isNull);
      expect(source.resetCalls, greaterThanOrEqualTo(2));

      controller.dispose();
    });

    test('账号切换返回的 Future 会等待自动清理完成', () async {
      final source = _FakeAcademicDataSource();
      final controller = _newController(source);

      await controller.syncAppUser('app-user-a');
      await controller.login(studentId: '2026000001', password: 'secret');
      final resetCallsBeforeSwitch = source.resetCalls;

      await controller.syncAppUser('app-user-b');

      expect(source.resetCalls, resetCallsBeforeSwitch + 1);
      expect(controller.studentId, isNull);
      expect(controller.sessionState, SessionState.unauthenticated);

      controller.dispose();
    });

    test('登录异常会转换为可渲染失败而不是抛出未处理 Future error', () async {
      final source = _FakeAcademicDataSource(
        loginError: StateError('模拟客户端初始化异常'),
      );
      final controller = _newController(source);

      await controller.syncAppUser('app-user-a');
      final result = await controller.login(
        studentId: '2026000001',
        password: 'secret',
      );

      expect(result, isA<LoginPageChanged>());
      expect(controller.status, AcademicSessionStatus.error);
      expect(controller.failure?.kind, AcademicFailureKind.unexpected);

      controller.dispose();
    });

    test('账号切换清理异常会被控制器收口且阻止复用旧会话', () async {
      final source = _FakeAcademicDataSource(
        resetError: StateError('模拟 Cookie 清理异常'),
      );
      final controller = _newController(source);

      await controller.syncAppUser('app-user-a');

      expect(controller.status, AcademicSessionStatus.error);
      expect(controller.isAuthenticated, isFalse);
      expect(controller.sessionState, SessionState.unauthenticated);
      expect(controller.failure?.kind, AcademicFailureKind.unexpected);
      expect(
        (await controller.login(
          studentId: '2026000001',
          password: 'secret',
        )),
        isA<LoginPageChanged>(),
      );
      expect(source.loginCalls, 0);

      controller.dispose();
    });

    test('登录成功后 Profile 会话失效时不会继续报告 authenticated', () async {
      final source = _FakeAcademicDataSource(
        profileError: const SessionExpiredException(),
      );
      final controller = _newController(source);

      await controller.syncAppUser('app-user-a');
      final result = await controller.login(
        studentId: '2026000001',
        password: 'secret',
      );

      expect(result, isA<LoginPageChanged>());
      expect(controller.status, AcademicSessionStatus.error);
      expect(controller.isAuthenticated, isFalse);
      expect(controller.failure?.kind, AcademicFailureKind.sessionExpired);

      controller.dispose();
    });

    test('认证成功但资料加载失败时保留认证并暴露资料错误状态', () async {
      final source = _FakeAcademicDataSource(
        profileError: const ProtocolChangedException(),
      );
      final controller = _newController(source);

      await controller.syncAppUser('app-user-a');
      final result = await controller.login(
        studentId: '2026000001',
        password: 'secret',
      );

      expect(result, isA<LoginSuccess>());
      expect(controller.isAuthenticated, isTrue);
      expect(controller.profile, isNull);
      expect(controller.profileStatus, AcademicProfileStatus.error);
      expect(controller.hasProfileError, isTrue);
      expect(controller.failure?.kind, AcademicFailureKind.protocolChanged);

      controller.dispose();
    });

    test('验证码刷新会话失效时退出 awaitingCaptcha', () async {
      final source = _FakeAcademicDataSource(
        captchaError: const SessionExpiredException(),
      );
      final controller = _newController(source);

      await controller.syncAppUser('app-user-a');
      await controller.refreshCaptcha();

      expect(controller.status, AcademicSessionStatus.error);
      expect(controller.isAwaitingCaptcha, isFalse);
      expect(controller.captchaChallenge, isNull);
      expect(controller.failure?.kind, AcademicFailureKind.sessionExpired);

      controller.dispose();
    });

    test('控制器会串行执行登录和课表操作', () async {
      final loginRelease = Completer<void>();
      final loginStarted = Completer<void>();
      final source = _FakeAcademicDataSource(
        loginGate: loginRelease.future,
        onLoginStarted: loginStarted.complete,
      );
      final controller = _newController(source);

      await controller.syncAppUser('app-user-a');
      final loginFuture = controller.login(
        studentId: '2026000001',
        password: 'secret',
      );
      await loginStarted.future;

      final coursesFuture = controller.loadCourses(
        year: '2026',
        semester: 3,
      );
      expect(source.courseCalls, 0);

      loginRelease.complete();
      await loginFuture;
      await coursesFuture;

      expect(source.calls.indexOf('login:start'),
          lessThan(source.calls.indexOf('course')));

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

  test('协调器只在验证码成功后保存凭据，并同步凭据偏好', () async {
    final source = _FakeAcademicDataSource(
      loginResult: const CaptchaRequired(),
      captcha: CaptchaChallenge(imageBytes: Uint8List.fromList([1, 2, 3])),
    );
    final controller = _newController(source);
    await controller.syncAppUser('app-user-a');
    final credentialStore = _MemoryAcademicCredentialStore();
    final preferences = MemoryPreferencesStore();
    final coordinator = AcademicLoginCoordinator(
      controller: controller,
      credentialStore: credentialStore,
      preferencesLoader: () async => preferences,
      persistencePolicy: AcademicPersistencePolicy(
        appUserId: 'app-user-a',
        preferences: preferences,
        academicStore: null,
        scheduleStore: null,
      ),
    );

    final pending = await coordinator.login(
      studentId: '2026000001',
      password: 'secret',
      saveCredentials: true,
      saveAcademicData: false,
    );
    expect(pending.kind, AcademicLoginOutcomeKind.captchaRequired);
    expect(credentialStore.value, isNull);
    expect(
      AcademicStoragePreferences(appUserId: 'app-user-a', store: preferences)
          .saveCredentials,
      isFalse,
    );

    final success = await coordinator.continueLoginWithCaptcha(code: '1234');

    expect(success.isSuccess, isTrue);
    expect(credentialStore.value?.studentId, '2026000001');
    expect(
      AcademicStoragePreferences(appUserId: 'app-user-a', store: preferences)
          .saveCredentials,
      isTrue,
    );
    controller.dispose();
  });

  test('协调器区分凭据错误和网络错误的删除策略', () async {
    final invalidSource = _FakeAcademicDataSource(
      loginResult: const InvalidCredentials(message: '教务账号或密码错误'),
    );
    final invalidController = _newController(invalidSource);
    await invalidController.syncAppUser('app-user-a');
    final invalidStore = _MemoryAcademicCredentialStore()
      ..value = const AcademicCredential(
        studentId: '2026000001',
        password: 'secret',
      );
    final invalidCoordinator = _newCoordinator(
      invalidController,
      invalidStore,
      MemoryPreferencesStore(),
    );

    final invalid = await invalidCoordinator.login(
      studentId: '2026000001',
      password: 'secret',
      saveCredentials: true,
      saveAcademicData: false,
    );
    expect(invalid.kind, AcademicLoginOutcomeKind.invalidCredentials);
    expect(invalidStore.value, isNull);
    invalidController.dispose();

    final networkSource = _FakeAcademicDataSource(
      loginResult: NetworkUnavailable(
        message: '教务网络连接失败',
        cause: const NetworkException(message: '教务网络连接失败'),
      ),
    );
    final networkController = _newController(networkSource);
    await networkController.syncAppUser('app-user-a');
    final networkStore = _MemoryAcademicCredentialStore()
      ..value = const AcademicCredential(
        studentId: '2026000001',
        password: 'secret',
      );
    final networkCoordinator = _newCoordinator(
      networkController,
      networkStore,
      MemoryPreferencesStore(),
    );

    final network = await networkCoordinator.login(
      studentId: '2026000001',
      password: 'secret',
      saveCredentials: true,
      saveAcademicData: false,
    );
    expect(network.kind, AcademicLoginOutcomeKind.networkFailure);
    expect(networkStore.value, isNotNull);
    networkController.dispose();
  });

  test('并发自动登录共享同一个学校登录请求', () async {
    final loginRelease = Completer<void>();
    final loginStarted = Completer<void>();
    final source = _FakeAcademicDataSource(
      loginGate: loginRelease.future,
      onLoginStarted: loginStarted.complete,
    );
    final controller = _newController(source);
    await controller.syncAppUser('app-user-a');
    final credentialStore = _MemoryAcademicCredentialStore()
      ..value = const AcademicCredential(
        studentId: '2026000001',
        password: 'secret',
      );
    final preferences = MemoryPreferencesStore();
    await AcademicStoragePreferences(
            appUserId: 'app-user-a', store: preferences)
        .setSaveCredentials(true);
    final coordinator =
        _newCoordinator(controller, credentialStore, preferences);

    final first = coordinator.ensureAuthenticated();
    await loginStarted.future;
    final second = coordinator.ensureAuthenticated();
    loginRelease.complete();

    final results = await Future.wait([first, second]);
    expect(results.every((result) => result.isSuccess), isTrue);
    expect(source.loginCalls, 1);
    controller.dispose();
  });

  test('凭据写入成功但偏好失败时会回滚 Secure Store', () async {
    final source = _FakeAcademicDataSource();
    final controller = _newController(source);
    await controller.syncAppUser('app-user-a');
    final credentialStore = _MemoryAcademicCredentialStore();
    final preferences = _FailingCredentialPreferenceStore();
    final coordinator = _newCoordinator(
      controller,
      credentialStore,
      preferences,
    );

    final result = await coordinator.login(
      studentId: '2026000001',
      password: 'secret',
      saveCredentials: true,
      saveAcademicData: false,
    );

    expect(result.isSuccess, isTrue);
    expect(result.saveCredentialWarning, isTrue);
    expect(credentialStore.value, isNull);
    expect(
      AcademicStoragePreferences(appUserId: 'app-user-a', store: preferences)
          .saveCredentials,
      isFalse,
    );
    controller.dispose();
  });

  testWidgets('资料加载失败时登录弹窗保留错误并提供重试', (tester) async {
    final source = _FakeAcademicDataSource(
      profileError: const ProtocolChangedException(),
    );
    final controller = _newController(source);
    await controller.syncAppUser('app-user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AcademicLoginDialog(controller: controller),
        ),
      ),
    );
    await tester.enterText(find.byType(TextFormField).at(0), '2026000001');
    await tester.enterText(find.byType(TextFormField).at(1), 'secret');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '登录教务'));
    await tester.pumpAndSettle();

    expect(source.loginCalls, 1);
    expect(find.byType(AcademicLoginDialog), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重试资料'), findsOneWidget);

    controller.dispose();
  });
}

AcademicLoginCoordinator _newCoordinator(
  AcademicSessionController controller,
  _MemoryAcademicCredentialStore credentialStore,
  AppPreferencesStore preferences,
) {
  return AcademicLoginCoordinator(
    controller: controller,
    credentialStore: credentialStore,
    preferencesLoader: () async => preferences,
    persistencePolicy: AcademicPersistencePolicy(
      appUserId: 'app-user-a',
      preferences: preferences,
      academicStore: null,
      scheduleStore: null,
    ),
  );
}

final class _MemoryAcademicCredentialStore implements AcademicCredentialStore {
  AcademicCredential? value;

  @override
  Future<AcademicCredential?> read(String appUserId) async => value;

  @override
  Future<void> write(String appUserId, AcademicCredential credential) async {
    value = credential;
  }

  @override
  Future<void> delete(String appUserId) async {
    value = null;
  }
}

final class _FailingCredentialPreferenceStore extends MemoryPreferencesStore {
  @override
  Future<bool> setBool(String key, bool value) {
    if (key.startsWith('academic_save_credentials_') && value) {
      return Future<bool>.value(false);
    }
    return super.setBool(key, value);
  }
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
    this.loginError,
    this.captchaError,
    this.resetError,
    this.loginGate,
    this.onLoginStarted,
  })  : courses = courses ??
            CourseFetchResult(courses: const [], source: CourseSource.desktop),
        grades = grades ?? GradeFetchResult(grades: const [], pages: 1);

  final LoginResult loginResult;
  final CaptchaChallenge? captcha;
  final StudentProfile profile;
  final CourseFetchResult courses;
  final GradeFetchResult grades;
  final Object? profileError;
  final Object? loginError;
  final Object? captchaError;
  final Object? resetError;
  final Future<void>? loginGate;
  final void Function()? onLoginStarted;

  SessionState _state = SessionState.unauthenticated;
  String? _studentId;
  String? lastPassword;
  int loginCalls = 0;
  int profileCalls = 0;
  int courseCalls = 0;
  int gradeCalls = 0;
  int resetCalls = 0;
  final List<String> calls = [];

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
    calls.add('login:start');
    onLoginStarted?.call();
    if (loginGate != null) await loginGate;
    if (loginError != null) throw loginError!;
    lastPassword = password;
    if (loginResult is LoginSuccess) {
      _studentId = (loginResult as LoginSuccess).studentId;
      _state = SessionState.authenticated;
    } else if (loginResult is CaptchaRequired) {
      _studentId = studentId;
      _state = SessionState.awaitingCaptcha;
    }
    calls.add('login:end');
    return loginResult;
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() async {
    if (captchaError != null) throw captchaError!;
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
    calls.add('profile');
    if (profileError != null) {
      if (profileError is SessionExpiredException) {
        _state = SessionState.expired;
      }
      throw profileError!;
    }
    return profile;
  }

  @override
  Future<CourseFetchResult> getCourses({
    required String year,
    required int semester,
  }) async {
    courseCalls++;
    calls.add('course');
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
    resetCalls++;
    if (resetError != null) throw resetError!;
    _state = SessionState.unauthenticated;
    _studentId = null;
  }

  @override
  void close() {}
}
