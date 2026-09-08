import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:shenliyuan/features/academic/data/academic_identity_client.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_captcha_recognizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/application/academic_login_coordinator.dart';
import 'package:shenliyuan/features/academic/domain/academic_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_failure.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/presentation/academic_login_dialog.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_policy.dart';
import 'package:shenliyuan/features/academic/storage/academic_storage_preferences.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/services/account_session_cleanup_coordinator.dart';

void main() {
  for (final code in [
    'ACADEMIC_CHALLENGE_REJECTED',
    'ACADEMIC_PROVIDER_UNAVAILABLE'
  ]) {
    test('身份验证静默提交按错误类型停止：$code', () async {
      AppPreferencesStore.setMockInitialValues({});
      final controller = AcademicSessionController(
          repository: AcademicRepositoryImpl(
              local: _FakeAcademicDataSource(),
              legacy: _FakeAcademicDataSource(),
              source: AcademicSourceKind.legacy),
          cleanupCoordinator: AccountSessionCleanupCoordinator());
      await controller.syncAppUser('app-user-a');
      var submissions = 0;
      var challenges = 0;
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path.endsWith('/verify')) {
          submissions++;
          handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                  requestOptions: options,
                  statusCode: 401,
                  data: {'code': code, 'error': 'fixture'})));
          return;
        }
        challenges++;
        handler
            .resolve(Response(requestOptions: options, statusCode: 200, data: {
          'challenge_required': true,
          'challenge_type': 'school_login',
          'provider_id': 'sylu_graduate',
          'student_id': 'G-001',
          'challenge_token': 'fixture-$challenges',
          'captcha': base64Encode([1, 2, 3]),
          'school_public_key':
              'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC3hzrH91c0OKgtaSB7GWGfDuUJsMrtiYThDXtJdrCr7exKt2fmIZngoFk71Dv/BPVQCHSuohNNvEV9VVDFSBhsP9xKEDAM4/2Lv+wlzN9CuZtLpV3Elo8VacjwMHcjTRmTchRBmijQzZRFrA2LM+qsH3U5tRM1uJFbfRMkBq24AwIDAQAB',
          'school_public_key_fingerprint': 'sha256:fixture',
          'expires_at': '2099-01-01T00:00:00Z',
        }));
      }));
      final coordinator = AcademicLoginCoordinator(
          controller: controller,
          identityClient: AcademicIdentityClient(dio),
          identityCaptchaRecognizerFactory: _IdentityRecognizer.new);
      final result = await coordinator.login(
          studentId: 'G-001',
          password: 'fixture',
          providerId: AcademicProviderId.syluGraduate,
          saveCredentials: true,
          saveAcademicData: false);
      final captchaError = code == 'ACADEMIC_CHALLENGE_REJECTED';
      expect(submissions, captchaError ? 2 : 1);
      expect(challenges, captchaError ? 3 : 1);
      expect(result.needsCaptcha, captchaError);
      coordinator.cancelIdentityVerification();
      controller.dispose();
      dio.close();
    });
  }
  for (final failures in [1, 2]) {
    test('研究生静默验证码失败 $failures 次后有限重试', () async {
      AppPreferencesStore.setMockInitialValues({});
      final source = _FakeAcademicDataSource(
          loginResult: const CaptchaRequired(),
          captcha: CaptchaChallenge(
              imageBytes: Uint8List.fromList([1]),
              suggestedCode: '1234',
              suggestionConfidence: .99))
        ..captchaFailures = failures;
      final controller = AcademicSessionController(
          repository: AcademicRepositoryImpl(
              local: source, legacy: source, source: AcademicSourceKind.local),
          identity: const AcademicIdentityKey(
              appUserId: 'app-user-a',
              providerId: AcademicProviderId.syluGraduate,
              studentId: '2026000001'),
          cleanupCoordinator: AccountSessionCleanupCoordinator());
      await controller.syncAppUser('app-user-a');
      final coordinator = _newCoordinator(controller,
          _MemoryAcademicCredentialStore(), MemoryPreferencesStore());
      final result = await coordinator.login(
          studentId: '2026000001',
          password: 'fixture',
          saveCredentials: true,
          saveAcademicData: false);
      expect(source.captchaSubmissions, 2);
      expect(result.isSuccess, failures == 1);
      expect(result.needsCaptcha, failures == 2);
      controller.dispose();
    });
  }
  testWidgets('保留旧本科身份时换绑入口允许切换研究生类型和学号', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final source = _FakeAcademicDataSource();
    final controller = AcademicSessionController(
      repository: AcademicRepositoryImpl(
          local: source, legacy: source, source: AcademicSourceKind.local),
      identity: const AcademicIdentityKey(
          appUserId: 'app-user-a',
          providerId: AcademicProviderId.syluUndergraduate,
          studentId: 'old-student'),
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
            body: MediaQuery(
                data: const MediaQueryData(
                    size: Size(800, 600), textScaler: TextScaler.linear(1.3)),
                child: AcademicLoginDialog(
                    controller: controller,
                    changeIdentity: true,
                    coordinator: _newCoordinator(
                        controller,
                        _MemoryAcademicCredentialStore(),
                        MemoryPreferencesStore()))))));
    await tester.pumpAndSettle();
    expect(find.text('身份已由学校教务确认，登录时不可切换类型'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<AcademicProviderId>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('研究生教务').last);
    await tester.pumpAndSettle();
    expect(find.text('研究生教务'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, 'new-student');
    expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller
            ?.text,
        'new-student');
    expect(controller.identity?.studentId, 'old-student');
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  test('服务端研究生挑战接入本机识别且释放识别器', () async {
    AppPreferencesStore.setMockInitialValues({});
    final controller = AcademicSessionController(
        repository: AcademicRepositoryImpl(
            local: _FakeAcademicDataSource(),
            legacy: _FakeAcademicDataSource(),
            source: AcademicSourceKind.legacy),
        cleanupCoordinator: AccountSessionCleanupCoordinator());
    await controller.syncAppUser('app-user-a');
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: {
        'challenge_required': true,
        'challenge_type': 'school_login',
        'provider_id': 'sylu_graduate',
        'student_id': 'G-001',
        'challenge_token': 'fixture',
        'captcha': base64Encode([1, 2, 3]),
        'school_public_key': 'fixture-key',
        'school_public_key_fingerprint': 'sha256:fixture',
        'expires_at': '2099-01-01T00:00:00Z',
      }));
    }));
    final recognizer = _IdentityRecognizer();
    final coordinator = AcademicLoginCoordinator(
        controller: controller,
        silentCaptcha: false,
        identityClient: AcademicIdentityClient(dio),
        identityCaptchaRecognizerFactory: () => recognizer);
    final result = await coordinator.login(
        studentId: 'G-001',
        password: 'fixture',
        providerId: AcademicProviderId.syluGraduate,
        saveCredentials: true,
        saveAcademicData: true);
    expect(result.needsCaptcha, isTrue);
    expect(controller.captchaChallenge?.suggestedCode, '1234');
    expect(recognizer.closed, isTrue);
    coordinator.cancelIdentityVerification();
    controller.dispose();
    dio.close();
  });

  testWidgets('点击登录后保留遮蔽密码并自动填入验证码候选', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1cAAAAASUVORK5CYII=');
    final source = _FakeAcademicDataSource(
        loginResult: const CaptchaRequired(),
        captcha: CaptchaChallenge(
            imageBytes: png, suggestedCode: '1234', suggestionConfidence: .99));
    final controller = _newController(source);
    await controller.syncAppUser('app-user-a');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AcademicLoginDialog(
                controller: controller,
                coordinator: _newCoordinator(
                    controller,
                    _MemoryAcademicCredentialStore(),
                    MemoryPreferencesStore())))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), '2026000001');
    await tester.enterText(find.byType(TextFormField).at(1), 'fixture');
    await tester.tap(find.widgetWithText(FilledButton, '登录教务'));
    await tester.pumpAndSettle();
    final password =
        tester.widget<TextFormField>(find.byType(TextFormField).at(1));
    expect(password.controller?.text, 'fixture');
    expect(find.text('1234'), findsOneWidget);
    expect(find.text('密码已在本次登录中保留，无需重新输入'), findsOneWidget);
    controller.dispose();
  });
  testWidgets('研究生验证码连续两次自动失败后才显示人工输入', (tester) async {
    AppPreferencesStore.setMockInitialValues({});
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1cAAAAASUVORK5CYII=',
    );
    final source = _FakeAcademicDataSource(
      loginResult: const CaptchaRequired(),
      captcha: CaptchaChallenge(
        imageBytes: png,
        suggestedCode: '1234',
        suggestionConfidence: .99,
      ),
    )..captchaFailures = 2;
    final controller = AcademicSessionController(
      repository: AcademicRepositoryImpl(
        local: source,
        legacy: _FakeAcademicDataSource(),
        source: AcademicSourceKind.local,
      ),
      identity: const AcademicIdentityKey(
        appUserId: 'app-user-a',
        providerId: AcademicProviderId.syluGraduate,
        studentId: '2026000001',
      ),
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AcademicLoginDialog(
            controller: controller,
            coordinator: _newCoordinator(
              controller,
              _MemoryAcademicCredentialStore(),
              MemoryPreferencesStore(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), 'fixture');
    await tester.tap(find.widgetWithText(FilledButton, '登录教务'));
    await tester.pumpAndSettle();

    expect(source.captchaSubmissions, 2);
    expect(find.text('请输入验证码'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '继续登录'), findsOneWidget);
    expect(find.text('密码已在本次登录中保留，无需重新输入'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  test('服务端展示挑战不会误用本机验证码会话', () async {
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1cAAAAASUVORK5CYII=',
    );
    final source = _FakeAcademicDataSource(
      loginResult: const CaptchaRequired(),
      captcha: CaptchaChallenge(imageBytes: png),
    );
    final controller = AcademicSessionController(
      repository: AcademicRepositoryImpl(
        local: source,
        legacy: _FakeAcademicDataSource(),
        source: AcademicSourceKind.local,
      ),
      identity: const AcademicIdentityKey(
        appUserId: 'app-user-a',
        providerId: AcademicProviderId.syluGraduate,
        studentId: '2026000001',
      ),
      cleanupCoordinator: AccountSessionCleanupCoordinator(),
    );
    await controller.syncAppUser('app-user-a');
    final coordinator = _newCoordinator(
      controller,
      _MemoryAcademicCredentialStore(),
      MemoryPreferencesStore(),
    );

    final login = await coordinator.login(
      studentId: '2026000001',
      password: 'fixture',
      saveCredentials: false,
      saveAcademicData: false,
    );
    expect(login.needsCaptcha, isTrue);
    expect(source.captchaSubmissions, 0);

    // 模拟课表入口接手时本机识别已完成。
    controller.presentCaptchaChallenge(
      png,
      suggestedCode: '1234',
      suggestionConfidence: .99,
    );
    final restored = await coordinator.ensureAuthenticated();

    expect(restored.isSuccess, isFalse);
    expect(source.captchaSubmissions, 0);
    expect(controller.isAuthenticated, isFalse);
    controller.dispose();
  });

  setUp(() {
    AppPreferencesStore.setMockInitialValues({});
  });

  group('AcademicSessionController', () {
    AcademicSessionController serverController(
            _FakeAcademicDataSource source) =>
        AcademicSessionController(
          repository: AcademicRepositoryImpl(
            local: _FakeAcademicDataSource(),
            legacy: source,
            source: AcademicSourceKind.legacy,
          ),
          cleanupCoordinator: AccountSessionCleanupCoordinator(),
        );

    test('服务端绑定在冷启动后恢复，不需要手机保存密码', () async {
      final source = _FakeAcademicDataSource(restoredStudentId: '2026000001');
      final controller = serverController(source);
      final startup = controller.syncAppUser('app-user-a');
      final coordinator = _newCoordinator(controller,
          _MemoryAcademicCredentialStore(), MemoryPreferencesStore());
      final outcome = await coordinator.ensureAuthenticated();
      await startup;
      expect(outcome.isSuccess, true);
      expect(controller.isAuthenticated, true);
      expect(source.restoreCalls, 1);
      expect(source.loginCalls, 0);
      controller.dispose();
    });

    test('服务端登录忽略本机保存密码偏好，仍可开启资料缓存', () async {
      final controller = serverController(_FakeAcademicDataSource());
      await controller.syncAppUser('app-user-a');
      final store = _MemoryAcademicCredentialStore();
      final preferences = MemoryPreferencesStore();
      final coordinator = _newCoordinator(controller, store, preferences);
      final result = await coordinator.login(
        studentId: '2026000001',
        password: 'test-password',
        saveCredentials: true,
        saveAcademicData: true,
      );
      expect(result.isSuccess, true);
      expect(store.value, isNull);
      expect((await coordinator.loadPreferences()).saveAcademicData, true);
      controller.dispose();
    });

    test('启动断网不会永久丢绑定，网络恢复后可再次恢复', () async {
      final source = _FakeAcademicDataSource(
        restoredStudentId: '2026000001',
        restoreError: const NetworkException(message: '网络暂不可用'),
      );
      final controller = serverController(source);
      await controller.syncAppUser('app-user-a');
      final coordinator = _newCoordinator(controller,
          _MemoryAcademicCredentialStore(), MemoryPreferencesStore());
      expect((await coordinator.ensureAuthenticated()).kind,
          AcademicLoginOutcomeKind.networkFailure);
      expect(controller.hasResolvedServerBindingStatus, isFalse);
      source.restoreError = null;
      expect((await coordinator.ensureAuthenticated()).isSuccess, true);
      expect(controller.failure, isNull);
      expect(controller.studentId, '2026000001');
      expect(controller.hasResolvedServerBindingStatus, isTrue);
      expect(source.loginCalls, 0);
      controller.dispose();
    });

    test('刷新服务端状态能同步授权撤销，登出不恢复其他账号绑定', () async {
      final source = _FakeAcademicDataSource(restoredStudentId: '2026000001');
      final controller = serverController(source);
      await controller.syncAppUser('app-user-a');
      source.restoredStudentId = null;
      await controller.restoreSession(force: true);
      expect(controller.isAuthenticated, false);
      expect(controller.studentId, isNull);
      final calls = source.restoreCalls;
      await controller.syncAppUser(null);
      expect(source.restoreCalls, calls);
      controller.dispose();
    });

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
      loginResult: const NetworkUnavailable(
        message: '教务网络连接失败',
        cause: NetworkException(message: '教务网络连接失败'),
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

  test('用户选择保存后偏好失败仍保留 Secure Store 密码', () async {
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
    expect(credentialStore.value?.password, 'secret');
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
          body: AcademicLoginDialog(
            controller: controller,
            coordinator: _newCoordinator(controller,
                _MemoryAcademicCredentialStore(), MemoryPreferencesStore()),
          ),
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

final class _IdentityRecognizer implements AcademicCaptchaRecognizer {
  bool closed = false;
  @override
  bool get isAvailable => true;
  @override
  Future<AcademicCaptchaRecognition> recognize(Uint8List bytes) async =>
      const AcademicCaptchaRecognition(text: '1234', confidence: .99);
  @override
  void close() {
    closed = true;
  }
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
    this.restoredStudentId,
    this.restoreError,
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
  int restoreCalls = 0;
  int captchaFailures = 0;
  int captchaSubmissions = 0;
  String? restoredStudentId;
  Object? restoreError;
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
    captchaSubmissions++;
    if (captchaFailures-- > 0) {
      throw const AcademicFailure(
          kind: AcademicFailureKind.challengeRejected,
          message: '验证码错误',
          code: 'CAPTCHA_INVALID');
    }
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
    String? providerTermId,
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
  Future<void> restoreSession() async {
    restoreCalls++;
    if (restoreError != null) throw restoreError!;
    _studentId = restoredStudentId;
    _state = _studentId == null
        ? SessionState.unauthenticated
        : SessionState.authenticated;
  }

  @override
  void close() {}
}
