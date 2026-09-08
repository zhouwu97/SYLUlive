import 'package:shenliyuan/features/academic/storage/academic_connection_store.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:shenliyuan/features/academic/application/academic_login_coordinator.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_identity_client.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_router_repository.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/datasource/jiaowu_local_data_source.dart';
import 'package:shenliyuan/features/academic/data/datasource/legacy_server_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_captcha_recognizer.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/presentation/academic_login_dialog.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_session_artifact_vault.dart';
import 'package:shenliyuan/models/user.dart';
import 'package:shenliyuan/platform/contracts/secure_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/edu_provider.dart';
import 'package:shenliyuan/screens/edu_screen.dart';
import 'package:shenliyuan/widgets/course/course_import_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppPreferencesStore.setMockInitialValues({}));

  test('已登录但服务端身份列表为空时为未绑定，且不请求旧教务接口', () async {
    final paths = <String>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        paths.add(o.path);
        h.resolve(Response(
            requestOptions: o, statusCode: 200, data: {'identities': []}));
      }));
    final router = AcademicProviderRouterRepository(
        legacy: AcademicRepositoryImpl(
            local: JiaowuLocalDataSource(),
            legacy: LegacyServerDataSource(dio),
            source: AcademicSourceKind.legacy),
        registry: AcademicProviderRegistry([_ProjectionProviderFactory()]),
        identityClient: AcademicIdentityClient(dio));
    final session = AcademicSessionController(repository: router);
    addTearDown(() {
      session.dispose();
      dio.close();
    });
    await session.syncAppUser('3');
    expect(session.academicState, AcademicState.identityUnbound);
    expect(paths, ['/student-identity']);
  });

  test('双身份切换只选择本机 Provider，冷启动恢复选择且不恢复连接许可', () async {
    final paths = <String>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        paths.add(o.path);
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'identities': [
            {
              'provider_id': 'sylu_undergraduate',
              'student_id': 'U1',
              'verified': true
            },
            {
              'provider_id': 'sylu_graduate',
              'student_id': 'G1',
              'verified': true
            },
          ]
        }));
      }));
    AcademicProviderRouterRepository makeRouter() =>
        AcademicProviderRouterRepository(
            legacy: AcademicRepositoryImpl(
                local: JiaowuLocalDataSource(),
                legacy: LegacyServerDataSource(dio),
                source: AcademicSourceKind.legacy),
            registry: AcademicProviderRegistry([
              _ProjectionProviderFactory(),
              _ProjectionProviderFactory(AcademicProviderId.syluUndergraduate)
            ]),
            identityClient: AcademicIdentityClient(dio));
    final session = AcademicSessionController(repository: makeRouter());
    await session.syncAppUser('3');
    final bindings = await session.providerRouter!.loadIdentityBindings();
    await session.selectProviderIdentity(bindings.last.toIdentity('3'));
    expect(session.providerId, AcademicProviderId.syluGraduate);
    expect(session.academicState, AcademicState.deviceSetupRequired);
    expect(await session.remoteAccessAllowed(), isFalse);
    session.dispose();
    final restarted = AcademicSessionController(repository: makeRouter());
    addTearDown(() {
      restarted.dispose();
      dio.close();
    });
    await restarted.syncAppUser('3');
    expect(restarted.providerId, AcademicProviderId.syluGraduate);
    expect(restarted.isBusy, isFalse);
    expect(paths.every((path) => path == '/student-identity'), isTrue);
  });
  test('账号切换时丢弃旧身份列表响应，不选择旧 Provider', () async {
    final adapter = _BlockingIdentityAdapter();
    final identityDio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api'))
      ..httpClientAdapter = adapter;
    final legacyDio = Dio();
    final router = AcademicProviderRouterRepository(
      legacy: AcademicRepositoryImpl(
        local: JiaowuLocalDataSource(),
        legacy: LegacyServerDataSource(legacyDio, networkEnabled: false),
        source: AcademicSourceKind.legacy,
      ),
      registry: AcademicProviderRegistry([_ProjectionProviderFactory()]),
      identityClient: AcademicIdentityClient(identityDio),
    );
    addTearDown(() {
      router.close();
      identityDio.close();
      legacyDio.close();
    });

    router.syncAppUser('old-user');
    final selection = router.ensureIdentitySelection();
    await adapter.started.future;
    router.syncAppUser('new-user');
    adapter.release();

    expect(await selection, isFalse);
    expect(router.selectedIdentity, isNull);
    expect(router.identityBindings, isEmpty);
  });

  test('同一 App 账号断开后也丢弃此前在途身份响应', () async {
    final adapter = _BlockingIdentityAdapter();
    final identityDio = Dio(BaseOptions(baseUrl: 'https://example.invalid/api'))
      ..httpClientAdapter = adapter;
    final legacyDio = Dio();
    final router = AcademicProviderRouterRepository(
      legacy: AcademicRepositoryImpl(
        local: JiaowuLocalDataSource(),
        legacy: LegacyServerDataSource(legacyDio, networkEnabled: false),
        source: AcademicSourceKind.legacy,
      ),
      registry: AcademicProviderRegistry([_ProjectionProviderFactory()]),
      identityClient: AcademicIdentityClient(identityDio),
    );
    addTearDown(() {
      router.close();
      identityDio.close();
      legacyDio.close();
    });

    router.syncAppUser('same-user');
    final selection = router.ensureIdentitySelection();
    await adapter.started.future;
    router.invalidateContext();
    adapter.release();

    expect(await selection, isFalse);
    expect(router.selectedIdentity, isNull);
    expect(router.identityBindings, isEmpty);
  });

  test('首次绑定本机未完成时取消保留已验证身份', () async {
    var unbindCalls = 0;
    final identityDio = Dio();
    identityDio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/student-identity/challenge') {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'challenge_required': true,
              'challenge_type': 'school_login',
              'provider_id': 'sylu_graduate',
              'student_id': 'G-CANCEL-001',
              'challenge_token': 'fixture-token',
              'captcha': base64Encode([1, 2, 3]),
              'school_public_key':
                  'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC3hzrH91c0OKgtaSB7GWGfDuUJsMrtiYThDXtJdrCr7exKt2fmIZngoFk71Dv/BPVQCHSuohNNvEV9VVDFSBhsP9xKEDAM4/2Lv+wlzN9CuZtLpV3Elo8VacjwMHcjTRmTchRBmijQzZRFrA2LM+qsH3U5tRM1uJFbfRMkBq24AwIDAQAB',
              'school_public_key_fingerprint': 'sha256:fixture',
              'expires_at': '2099-01-01T00:00:00Z',
            },
          ));
          return;
        }
        if (options.path == '/student-identity/verify') {
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'verified': true,
              'provider_id': 'sylu_graduate',
              'student_id': 'G-CANCEL-001',
            },
          ));
          return;
        }
        if (options.path == '/student-identity' && options.method == 'DELETE') {
          unbindCalls++;
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'unbound': true},
          ));
          return;
        }
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: options, statusCode: 404),
        ));
      },
    ));
    final legacyDio = Dio();
    final identityClient = AcademicIdentityClient(identityDio);
    final router = AcademicProviderRouterRepository(
      legacy: AcademicRepositoryImpl(
        local: JiaowuLocalDataSource(),
        legacy: LegacyServerDataSource(legacyDio, networkEnabled: false),
        source: AcademicSourceKind.legacy,
      ),
      registry: AcademicProviderRegistry([_ProjectionProviderFactory()]),
      identityClient: identityClient,
    );
    final session = AcademicSessionController(repository: router);
    final coordinator = AcademicLoginCoordinator(
      controller: session,
      identityClient: identityClient,
      preferencesLoader: () async => MemoryPreferencesStore(),
      identityCaptchaRecognizerFactory: _ProjectionRecognizer.new,
    );
    addTearDown(() {
      session.dispose();
      router.close();
      identityDio.close();
      legacyDio.close();
    });
    await session.syncAppUser('app-user-a');

    final outcome = await coordinator.login(
      studentId: 'G-CANCEL-001',
      password: 'fixture-password',
      saveCredentials: false,
      saveAcademicData: false,
      providerId: AcademicProviderId.syluGraduate,
    );
    expect(outcome.isSuccess, isFalse);
    expect(session.hasBoundIdentity, isTrue);
    expect((await coordinator.cancelLogin()).isSuccess, isTrue);
    expect(unbindCalls, 0);
    expect(session.identity?.studentId, 'G-CANCEL-001');
    expect(session.academicState, AcademicState.deviceSetupRequired);
  });

  testWidgets('首次绑定过程中切到本机 Provider 时弹窗不变成直连登录', (tester) async {
    final legacyDio = Dio();
    final router = AcademicProviderRouterRepository(
      legacy: AcademicRepositoryImpl(
        local: JiaowuLocalDataSource(),
        legacy: LegacyServerDataSource(legacyDio, networkEnabled: false),
        source: AcademicSourceKind.legacy,
      ),
      registry: AcademicProviderRegistry([_ProjectionProviderFactory()]),
    );
    final session = AcademicSessionController(repository: router);
    addTearDown(() {
      session.dispose();
      router.close();
      legacyDio.close();
    });
    await session.syncAppUser('app-user-a');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AcademicLoginDialog(controller: session)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('绑定教务账号'), findsOneWidget);

    await session.selectProviderIdentity(const AcademicIdentityKey(
      appUserId: 'app-user-a',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-CANCEL-001',
    ));
    await tester.pump();

    expect(find.text('绑定教务账号'), findsOneWidget);
    expect(find.text('本机直连教务'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('账号切换发生在 Artifact 读取期间时不恢复旧 Provider', () async {
    const identity = AcademicIdentityKey(
      appUserId: 'old-user',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-RESTART-001',
    );
    final provider = _CountingUnrestoredProvider(identity);
    final artifactBackend = _BlockingArtifactBackend();
    final session = AcademicSessionController.forProvider(
      provider: provider,
      identity: identity,
      sessionArtifactVaultFactory: (currentIdentity) =>
          AcademicSessionArtifactVault(
        identity: currentIdentity,
        secretStore: MemorySecretStore(),
        fileBackend: artifactBackend,
      ),
    );
    addTearDown(session.dispose);

    await AcademicConnectionStore(
            identity, await AppPreferencesStore.getInstance())
        .setConnected(true);
    await session.syncAppUser('old-user');
    final restore = session.ensureAuthenticated();
    await artifactBackend.started.future;
    final switchAccount = session.syncAppUser('new-user');
    artifactBackend.release();

    expect(await restore, isFalse);
    await switchAccount;
    expect(provider.restoreArtifactCalls, 0);
    expect(provider.probeCalls, 0);
  });

  test('断开连接发生在 Artifact 读取期间时不恢复 Provider', () async {
    const identity = AcademicIdentityKey(
      appUserId: 'old-user',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-RESTART-001',
    );
    final provider = _CountingUnrestoredProvider(identity);
    final artifactBackend = _BlockingArtifactBackend();
    final session = AcademicSessionController.forProvider(
      provider: provider,
      identity: identity,
      sessionArtifactVaultFactory: (currentIdentity) =>
          AcademicSessionArtifactVault(
        identity: currentIdentity,
        secretStore: MemorySecretStore(),
        fileBackend: artifactBackend,
      ),
    );
    addTearDown(session.dispose);

    await AcademicConnectionStore(
            identity, await AppPreferencesStore.getInstance())
        .setConnected(true);
    await session.syncAppUser('old-user');
    final restore = session.ensureAuthenticated();
    await artifactBackend.started.future;
    final disconnect = session.disconnect();
    artifactBackend.release();

    expect(await restore, isFalse);
    await disconnect;
    expect(provider.restoreArtifactCalls, 0);
    expect(provider.probeCalls, 0);
    expect(session.connectionPreference,
        AcademicConnectionPreference.disconnected);
  });

  testWidgets('已验证研究生身份但本机会话未恢复仍显示已绑定', (tester) async {
    const identity = AcademicIdentityKey(
      appUserId: '3',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-RESTART-001',
    );
    final session = AcademicSessionController.forProvider(
      provider: _UnrestoredProvider(identity),
      identity: identity,
    );
    final edu = EduProvider(Dio())..setAcademicSessionController(session);
    final auth = _ProjectionAuth(Dio());
    addTearDown(() {
      auth.dispose();
      edu.dispose();
      session.dispose();
    });

    await AcademicConnectionStore(
            identity, await AppPreferencesStore.getInstance())
        .setConnected(true);
    await session.syncAppUser('3');
    final restored = await session.ensureAuthenticated();
    edu.setUserId('3');
    await edu.ensureStatusLoaded();

    expect(restored, isFalse);
    expect(session.hasBoundIdentity, isTrue);
    expect(session.isAuthenticated, isFalse);
    expect(edu.isBound, isTrue);
    expect(edu.isAuthorized, isTrue);
    expect(edu.sessionState, 'expired');

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<EduProvider>.value(value: edu),
          ChangeNotifierProvider<AcademicSessionController>.value(
            value: session,
          ),
          Provider<AcademicLoginCoordinator>(
            create: (_) => AcademicLoginCoordinator(controller: session),
          ),
        ],
        child: const MaterialApp(home: EduScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('身份已验证 · 本机待连接'), findsOneWidget);
    expect(find.text('未绑定教务账号'), findsNothing);
    expect(
      find.text('研究生教务当前开放课表；成绩、考试和 GPA 暂未接入'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('可信身份打开登录弹窗时预填并锁定研究生学号', (tester) async {
    const identity = AcademicIdentityKey(
      appUserId: '3',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-RESTART-001',
    );
    final session = AcademicSessionController.forProvider(
      provider: _UnrestoredProvider(identity),
      identity: identity,
    );
    final auth = _ProjectionAuth(Dio());
    addTearDown(() {
      auth.dispose();
      session.dispose();
    });
    await AcademicConnectionStore(
            identity, await AppPreferencesStore.getInstance())
        .setConnected(true);
    await session.syncAppUser('3');

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<AcademicSessionController>.value(
            value: session,
          ),
          Provider<AcademicLoginCoordinator>(
            create: (_) => AcademicLoginCoordinator(controller: session),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: AcademicLoginDialog(controller: session),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('研究生教务'), findsOneWidget);
    expect(find.text('G-RESTART-001'), findsOneWidget);
    final studentField = tester.widget<TextField>(
      find.byType(TextField).first,
    );
    expect(studentField.readOnly, isTrue);
    expect(find.text('身份已由学校教务确认，登录时不可切换类型'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('课表读取前本机会话失效会打开本机登录框', (tester) async {
    const identity = AcademicIdentityKey(
      appUserId: '3',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-RESTART-001',
    );
    final session = AcademicSessionController.forProvider(
      provider: _UnrestoredProvider(identity),
      identity: identity,
    );
    final coordinator = AcademicLoginCoordinator(
      controller: session,
      credentialStore: _EmptyCredentialStore(),
      preferencesLoader: () async => MemoryPreferencesStore(),
    );
    addTearDown(session.dispose);
    await AcademicConnectionStore(
            identity, await AppPreferencesStore.getInstance())
        .setConnected(true);
    await session.syncAppUser('3');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox()),
      ),
    );
    final pageContext = tester.element(find.byType(Scaffold));
    final readyFuture = ensureAcademicSessionForRead(
      pageContext,
      controller: session,
      coordinator: coordinator,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('本机直连教务'), findsOneWidget);
    expect(find.text('G-RESTART-001'), findsOneWidget);
    expect(find.text('身份已由学校教务确认，登录时不可切换类型'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await readyFuture, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有效会话材料让课表读取前置静默继续', (tester) async {
    const identity = AcademicIdentityKey(
      appUserId: '3',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-RESTART-001',
    );
    final secretStore = MemorySecretStore();
    final fileBackend = MemoryAcademicSessionArtifactFileBackend();
    final vault = AcademicSessionArtifactVault(
      identity: identity,
      secretStore: secretStore,
      fileBackend: fileBackend,
    );
    await vault.write(
      ProviderSessionArtifact(
        providerId: identity.providerId,
        studentId: identity.studentId,
        artifactVersion: 1,
        createdAt: DateTime.now().toUtc(),
        validatedAt: DateTime.now().toUtc(),
        opaqueProviderState: const <String, Object?>{'restored': true},
      ),
    );
    final provider = _ArtifactProvider(identity);
    final session = AcademicSessionController.forProvider(
      provider: provider,
      identity: identity,
      sessionArtifactVaultFactory: (_) => vault,
    );
    final coordinator = AcademicLoginCoordinator(
      controller: session,
      credentialStore: _EmptyCredentialStore(),
      preferencesLoader: () async => MemoryPreferencesStore(),
    );
    addTearDown(session.dispose);
    await AcademicConnectionStore(
            identity, await AppPreferencesStore.getInstance())
        .setConnected(true);
    await session.syncAppUser('3');

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    final pageContext = tester.element(find.byType(Scaffold));
    final readyFuture = ensureAcademicSessionForRead(
      pageContext,
      controller: session,
      coordinator: coordinator,
    );
    await tester.pump();

    expect(await readyFuture, isTrue);
    expect(provider.restoreArtifactCalls, 1);
    expect(find.byType(AcademicLoginDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('课表读取前置跨账号后丢弃旧恢复结果', (tester) async {
    const identity = AcademicIdentityKey(
      appUserId: 'old-user',
      providerId: AcademicProviderId.syluGraduate,
      studentId: 'G-RESTART-001',
    );
    final artifactBackend = _BlockingArtifactBackend();
    final session = AcademicSessionController.forProvider(
      provider: _CountingUnrestoredProvider(identity),
      identity: identity,
      sessionArtifactVaultFactory: (currentIdentity) =>
          AcademicSessionArtifactVault(
        identity: currentIdentity,
        secretStore: MemorySecretStore(),
        fileBackend: artifactBackend,
      ),
    );
    final coordinator = AcademicLoginCoordinator(
      controller: session,
      credentialStore: _EmptyCredentialStore(),
      preferencesLoader: () async => MemoryPreferencesStore(),
    );
    addTearDown(session.dispose);
    await AcademicConnectionStore(
            identity, await AppPreferencesStore.getInstance())
        .setConnected(true);
    await session.syncAppUser('old-user');

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    final pageContext = tester.element(find.byType(Scaffold));
    final readyFuture = ensureAcademicSessionForRead(
      pageContext,
      controller: session,
      coordinator: coordinator,
    );
    await artifactBackend.started.future;
    final switchAccount = session.syncAppUser('new-user');
    artifactBackend.release();

    expect(await readyFuture, isFalse);
    await switchAccount;
    expect(find.byType(AcademicLoginDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('课表拉取失败保留选学期并显示可重试错误', (tester) async {
    final edu = _FailingCourseEduProvider();
    addTearDown(edu.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CourseImportSheet(eduProvider: edu),
        ),
      ),
    );
    await tester.tap(find.text('拉取课表'));
    await tester.pumpAndSettle();

    expect(edu.calls, 1);
    expect(find.text('本机教务会话已失效，请重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('再次拉取课表'), findsOneWidget);
    expect(find.byType(CourseImportSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本机课表选择器使用学校真实学期标识', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final edu = _TermEduProvider();
    addTearDown(edu.dispose);
    Future<CourseImportResult?>? resultFuture;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                resultFuture = CourseImportSheet.show(
                  context,
                  eduProvider: edu,
                );
              },
              child: const Text('打开选择器'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开选择器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('2026-2027 第一学期'), findsOneWidget);
    final pullButton =
        tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    pullButton.onPressed!();
    await tester.pump();
    await tester.pumpAndSettle();

    final result = await resultFuture!;
    expect(result?.term.providerTermId, 'graduate-term-2026-1');
    expect(edu.requestedProviderTermId, 'graduate-term-2026-1');
    expect(tester.takeException(), isNull);
  });
}

final class _EmptyCredentialStore implements AcademicCredentialStore {
  @override
  Future<AcademicCredential?> read(String appUserId) async => null;

  @override
  Future<void> write(String appUserId, AcademicCredential credential) async {}

  @override
  Future<void> delete(String appUserId) async {}
}

final class _ProjectionRecognizer implements AcademicCaptchaRecognizer {
  @override
  bool get isAvailable => true;

  @override
  Future<AcademicCaptchaRecognition> recognize(Uint8List imageBytes) async =>
      const AcademicCaptchaRecognition(text: '1234', confidence: .99);

  @override
  void close() {}
}

final class _FailingCourseEduProvider extends EduProvider {
  _FailingCourseEduProvider() : super(Dio());

  int calls = 0;

  @override
  Future<OperationResult<List<Map<String, dynamic>>>?> getCourses(
    String year,
    int semester, {
    String? providerTermId,
  }) async {
    calls++;
    return OperationResult.fail('本机教务会话已失效，请重试');
  }
}

final class _TermEduProvider extends EduProvider {
  _TermEduProvider() : super(Dio());

  String? requestedProviderTermId;

  @override
  bool get isUsingLocalAcademicSession => true;

  @override
  Future<OperationResult<List<AcademicTerm>>?> getAcademicTerms() async =>
      OperationResult.ok(const <AcademicTerm>[
        AcademicTerm(
          providerId: AcademicProviderId.syluGraduate,
          providerTermId: 'graduate-term-2026-1',
          displayName: '2026-2027 第一学期',
          isCurrent: true,
        ),
      ]);

  @override
  Future<OperationResult<List<Map<String, dynamic>>>?> getCourses(
    String year,
    int semester, {
    String? providerTermId,
  }) async {
    requestedProviderTermId = providerTermId;
    return OperationResult.ok(const <Map<String, dynamic>>[]);
  }
}

final class _ProjectionAuth extends AuthProvider {
  _ProjectionAuth(super.dio) : super(loadStoredAuth: false);

  @override
  User get user => User(
        id: 3,
        studentId: '',
        nickname: '测试用户',
        createdAt: DateTime(2026),
      );

  @override
  bool get isLoggedIn => true;
}

final class _ProjectionProviderFactory implements AcademicProviderFactory {
  _ProjectionProviderFactory([this.id = AcademicProviderId.syluGraduate]);
  @override
  final AcademicProviderId id;

  @override
  AcademicProvider create(AcademicIdentityKey identity) =>
      _UnrestoredProvider(identity);
}

final class _ArtifactProvider extends _UnrestoredProvider {
  _ArtifactProvider(super.identity);

  int restoreArtifactCalls = 0;
  bool _authenticated = false;

  @override
  Future<void> restoreSession(ProviderSessionArtifact artifact) async {
    restoreArtifactCalls++;
    _authenticated = true;
  }

  @override
  Future<AcademicSessionProbeResult> probeSession() async =>
      AcademicSessionProbeResult(
        authenticated: _authenticated,
        confirmedStudentId: _authenticated ? identity.studentId : null,
      );
}

class _UnrestoredProvider implements AcademicProvider {
  _UnrestoredProvider(this.identity);

  @override
  final AcademicIdentityKey identity;

  @override
  AcademicProviderId get id => identity.providerId;

  @override
  AcademicProviderCapabilities get capabilities =>
      const AcademicProviderCapabilities(timetable: true);

  @override
  Future<AcademicLoginChallenge> prepareLogin() async =>
      const NoLoginChallenge();

  @override
  Future<AcademicLoginResult> login(AcademicLoginRequest request) async =>
      const AcademicLoginRejected(
        error: AcademicAuthFailure(
          AcademicAuthFailureType.authRejectedAmbiguous,
          '测试 Provider 未建立本机会话',
        ),
      );

  @override
  Future<void> restoreSession(ProviderSessionArtifact artifact) async {}

  @override
  Future<AcademicSessionProbeResult> probeSession() async =>
      const AcademicSessionProbeResult(authenticated: false);

  @override
  Future<List<AcademicTerm>> fetchTerms() async => const [];

  @override
  Future<AcademicSchedule> fetchSchedule(String providerTermId) async =>
      AcademicSchedule(occurrences: const []);

  @override
  Future<ProviderSessionArtifact?> exportSession() async => null;

  @override
  Future<void> clearSession() async {}

  @override
  void close() {}
}

final class _CountingUnrestoredProvider extends _UnrestoredProvider {
  _CountingUnrestoredProvider(super.identity);

  int restoreArtifactCalls = 0;
  int probeCalls = 0;

  @override
  Future<void> restoreSession(ProviderSessionArtifact artifact) async {
    restoreArtifactCalls++;
  }

  @override
  Future<AcademicSessionProbeResult> probeSession() async {
    probeCalls++;
    return super.probeSession();
  }
}

final class _BlockingIdentityAdapter implements HttpClientAdapter {
  final Completer<void> started = Completer<void>();
  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!started.isCompleted) started.complete();
    await _release.future;
    return ResponseBody.fromString(
      '{"identities":[{"provider_id":"sylu_graduate","student_id":"G-OLD","verified":true}]}',
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _BlockingArtifactBackend
    implements AcademicSessionArtifactFileBackend {
  final Completer<void> started = Completer<void>();
  final Completer<void> _release = Completer<void>();

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<Uint8List?> read(String storageId) async {
    if (!started.isCompleted) started.complete();
    await _release.future;
    return null;
  }

  @override
  Future<void> write(String storageId, Uint8List bytes) async {}

  @override
  Future<void> delete(String storageId) async {}
}
