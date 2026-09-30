import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_storage_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/datasource/jiaowu_local_data_source.dart';
import 'package:shenliyuan/features/academic/data/datasource/legacy_server_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/presentation/academic_login_dialog.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_router_repository.dart';
import 'package:shenliyuan/features/academic/data/academic_identity_client.dart';
import 'package:shenliyuan/features/academic/data/academic_account_config_client.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/storage/local_academic_account_store.dart';
import 'package:shenliyuan/providers/edu_provider.dart';

import '../../helpers/golden_test_app.dart';
import '../../helpers/golden_viewport.dart';
import '../../helpers/load_test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const reminderChannel = MethodChannel('shenliyuan/course_reminders');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  final secureStore = <String, String>{};
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('academic_binding_test_');
    AppPreferencesStore.setMockInitialValues({});
    secureStore.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      switch (call.method) {
        case 'getTemporaryDirectory':
        case 'getApplicationSupportDirectory':
        case 'getApplicationDocumentsDirectory':
          return tempDir.path;
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final args =
          Map<String, dynamic>.from((call.arguments as Map?) ?? const {});
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secureStore[key];
        case 'write':
          if (key != null) secureStore[key] = args['value'] as String;
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(reminderChannel, (call) async => null);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(reminderChannel, null);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  late Dio dio;
  late AcademicSessionController controller;
  late EduProvider provider;
  late List<RequestOptions> requests;
  bool authorized = false;
  bool rejectRevoke = false;
  bool expireSession = false;
  bool rejectResume = false;
  int revokeStatus = 200;
  Completer<void>? loginGate;

  void initialize() {
    AppPreferencesStore.setMockInitialValues({});
    authorized = false;
    rejectRevoke = false;
    expireSession = false;
    rejectResume = false;
    revokeStatus = 200;
    loginGate = null;
    requests = [];
    dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        requests.add(options);
        if (options.path == '/edu/bind') {
          if (loginGate != null) await loginGate!.future;
          authorized = true;
        }
        if (options.path == '/edu/session/resume') {
          if (rejectResume) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              message: '网络连接失败',
            ));
            return;
          }
          expireSession = false;
        }
        if (options.path == '/edu/authorization') {
          if (rejectRevoke) {
            handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              message: '网络连接失败',
            ));
            return;
          }
          authorized = false;
        }
        handler.resolve(Response(
          requestOptions: options,
          statusCode: options.path == '/edu/authorization' ? revokeStatus : 200,
          data: {
            'success': true,
            'edu_authorized': authorized,
            'edu_student_id': authorized ? '2026000001' : '',
            'edu_session_state':
                authorized ? (expireSession ? 'expired' : 'active') : 'unbound',
          },
        ));
      },
    ));
    final repository = AcademicRepositoryImpl(
      local: JiaowuLocalDataSource(),
      legacy: LegacyServerDataSource(dio, networkEnabled: true),
      source: AcademicSourceKind.legacy,
    );
    controller = AcademicSessionController(repository: repository);
    provider = EduProvider(dio)..setAcademicSessionController(controller);
    addTearDown(() {
      provider.dispose();
      controller.dispose();
      repository.close();
      dio.close();
    });
  }

  Future<void> openDialog(
    WidgetTester tester, {
    bool saveData = false,
    ThemeMode theme = ThemeMode.light,
    TextScaler scaler = TextScaler.noScaling,
  }) async {
    await tester.runAsync(() async {
      initialize();
      final preferences = AcademicStoragePreferences(
          appUserId: 'test-app-user',
          store: await AppPreferencesStore.getInstance());
      await preferences.setSaveAcademicData(saveData);
      await controller.syncAppUser('test-app-user');
    });
    await setGoldenViewport(tester, GoldenViewports.phone360x800);
    await tester.pumpWidget(GoldenTestApp(
      themeMode: theme,
      textScaler: scaler,
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                    onPressed: () => AcademicLoginDialog.show(
                      context,
                      controller: controller,
                    ),
                    child: const Text('打开绑定'),
                  ))),
    ));
    await tester.tap(find.text('打开绑定'));
    await tester.pumpAndSettle();
  }

  for (final saveData in [false, true]) {
    testWidgets('绑定保留资料缓存选择 $saveData，明确授权后发送且禁止重复提交', (tester) async {
      await openDialog(tester, saveData: saveData);
      expect(find.text('绑定教务账号'), findsOneWidget);
      expect(find.textContaining('本设备直接登录所选教务系统'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(2));
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
      final button = find.widgetWithText(FilledButton, '同意并绑定');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.enterText(find.byType(TextFormField).at(0), '2026000001');
      await tester.enterText(find.byType(TextFormField).at(1), 'test-password');
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.path == '/edu/bind'), isEmpty);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isTrue);
      loginGate = Completer<void>();
      await tester.tap(button);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(controller.isBusy, isTrue);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).at(1))
              .controller!
              .text,
          'test-password');
      expect(
          tester
              .widget<EditableText>(find.byType(EditableText).at(1))
              .obscureText,
          isTrue);
      loginGate!.complete();
      // 凭据及缓存清理包含真实异步调用，等待弹窗完成整个登录流程。
      for (var attempt = 0;
          attempt < 100 &&
              find.byType(AcademicLoginDialog).evaluate().isNotEmpty;
          attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(find.byType(AcademicLoginDialog), findsNothing);
      final binding = requests.singleWhere((r) => r.path == '/edu/bind');
      expect(binding.data['edu_data_consent_accepted'], isTrue);
      expect(controller.isAuthenticated, isTrue);
      final storedChoice = await tester.runAsync(() async {
        final preferences = AcademicStoragePreferences(
            appUserId: 'test-app-user',
            store: await AppPreferencesStore.getInstance());
        return preferences.saveAcademicData;
      });
      expect(storedChoice, saveData);
    });
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('授权说明可打开，1.3倍字号无溢出：${theme.name}', (tester) async {
      await openDialog(tester,
          theme: theme, scaler: GoldenTextProfile.large.scaler);
      expect(tester.takeException(), isNull);
      final link = find.text('查看教务数据专项授权');
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(
          find.textContaining('教务登录和身份核验会按你选择的功能使用不同凭据路径'),
          findsOneWidget,
        );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.byType(AcademicLoginDialog), findsNothing);
      expect(requests.where((r) => r.path == '/edu/bind'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  test('过期会话恢复失败保留绑定，重试通过服务端凭据恢复且不重新绑定', () async {
    initialize();
    authorized = true;
    await controller.syncAppUser('test-app-user');
    expireSession = true;
    rejectResume = true;
    await expectLater(controller.restoreSession(force: true), throwsException);
    expect(controller.isAuthenticated, false);
    expect(provider.isBound, true);
    expect(controller.studentId, '2026000001');
    rejectResume = false;
    await controller.restoreSession();
    expect(controller.isAuthenticated, true);
    expect(controller.failure, isNull);
    final resumes =
        requests.where((request) => request.path == '/edu/session/resume');
    expect(resumes.length, 2);
    expect(resumes.every((request) => request.data == null), true);
    expect(requests.where((request) => request.path == '/edu/bind'), isEmpty);
  });

  test('未同意专项授权时 Provider 也不发出绑定请求', () async {
    initialize();
    expect(
        await provider.bind('2026000001', 'test-password',
            eduDataConsentAccepted: false),
        isFalse);
    expect(requests.where((r) => r.path == '/edu/bind'), isEmpty);
  });

  for (final status in [200, 202]) {
    test('解绑撤销服务器授权，重新恢复不会再次绑定：HTTP $status', () async {
      initialize();
      await controller.syncAppUser('test-app-user');
      await controller.login(
          studentId: '2026000001', password: 'test-password');
      await controller.resetSession();
      await controller.restoreSession();
      expect(controller.isAuthenticated, isTrue);
      revokeStatus = status;
      final result = await provider.unbind();
      expect(result.success, isTrue);
      expect(requests.singleWhere((r) => r.path == '/edu/authorization').method,
          'DELETE');
      await controller.restoreSession();
      expect(controller.isAuthenticated, isFalse);
      expect(provider.isBound, isFalse);
    });
  }

  test('撤销失败保留绑定状态并返回错误，允许重试', () async {
    initialize();
    await controller.syncAppUser('test-app-user');
    await controller.login(studentId: '2026000001', password: 'test-password');
    rejectRevoke = true;
    expect((await provider.unbind()).success, isFalse);
    expect(controller.isAuthenticated, isTrue);
    expect(provider.isBound, isTrue);
    rejectRevoke = false;
    expect((await provider.unbind()).success, isTrue);
    expect(provider.isBound, isFalse);
  });

  test('A 解绑清理期间切到 B，B 相同 provider 与学号的 pending 任务不被误确认', () async {
    final prefs = await AppPreferencesStore.getInstance();
    const studentId = '2026000001';
    const idA = AcademicIdentityKey(
      appUserId: 'user-a',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: studentId,
    );
    const idB = AcademicIdentityKey(
      appUserId: 'user-b',
      providerId: AcademicProviderId.syluUndergraduate,
      studentId: studentId,
    );

    // 初始化 User B 的 Store，并拥有相同 provider 和相同学号的待清理任务
    final storeB = LocalAcademicAccountStore('user-b', prefs);
    await storeB.commitIdentity(idB);
    await storeB.mergeSnapshot({
      'provider_id': idB.providerId.value,
      'student_id': 'other-student',
      'revision': 2,
      'state': 'active',
    });
    await storeB.adoptCloud(idB.providerId, allowLegacyCleanup: true);
    expect(storeB.pendingCleanup, contains(idB));
    expect(storeB.cleanupIncludesLegacy(idB), isTrue);

    // 初始化 User A 的 Router 和 Store
    final localDio = Dio();
    final router = AcademicProviderRouterRepository(
      legacy: AcademicRepositoryImpl(
        local: JiaowuLocalDataSource(),
        legacy: LegacyServerDataSource(localDio, networkEnabled: false),
        source: AcademicSourceKind.legacy,
      ),
      registry: AcademicProviderRegistry([
        _TestProviderFactory(AcademicProviderId.syluUndergraduate),
      ]),
    );
    final sessionController = AcademicSessionController(repository: router);
    final eduProvider = EduProvider(localDio)
      ..setAcademicSessionController(sessionController);

    await sessionController.syncAppUser('user-a');
    final storeA = LocalAcademicAccountStore('user-a', prefs);
    await storeA.commitIdentity(idA);
    await sessionController.selectProviderIdentity(idA);

    // User A 发起 unbind()
    // 在解绑执行期间切到 User B
    final unbindFuture = eduProvider.unbind();
    await sessionController.syncAppUser('user-b');
    final result = await unbindFuture;
    expect(result.success, isTrue);

    // 断言：
    // 1. User B 的待清理任务绝不能被 User A 的 unbind 误删或误确认！
    final checkStoreB = LocalAcademicAccountStore('user-b', prefs);
    expect(checkStoreB.pendingCleanup, contains(idB));
    expect(checkStoreB.cleanupIncludesLegacy(idB), isTrue);

    // 2. User A 的 Store A 中 idA 的清理任务已被正常确认
    final checkStoreA = LocalAcademicAccountStore('user-a', prefs);
    expect(checkStoreA.pendingCleanup, isEmpty);

    sessionController.dispose();
    eduProvider.dispose();
    router.close();
    localDio.close();
  });

  group('新版可信身份解绑走 /student-identity', () {
    late Dio dio;
    late List<RequestOptions> requests;
    late AcademicSessionController session;
    late EduProvider provider;
    bool rejectIdentityUnbind = false;

    Response<dynamic> _configResponse(RequestOptions options) => Response(
          requestOptions: options,
          statusCode: 200,
          data: options.path == '/academic-account-configs'
              ? {
                  'configs': [
                    {
                      'provider_id': 'sylu_undergraduate',
                      'student_id': '2026000001',
                      'revision': 2,
                      'state': 'active',
                    }
                  ],
                }
              : {
                  'config': {
                    'provider_id': 'sylu_undergraduate',
                    'student_id': '',
                    'revision': 3,
                    'state': 'deleted',
                  }
                },
        );

    void initializeRouter() {
      AppPreferencesStore.setMockInitialValues({});
      rejectIdentityUnbind = false;
      requests = [];
      dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests.add(options);
          if (options.path == '/student-identity' &&
              options.method == 'DELETE') {
            if (rejectIdentityUnbind) {
              handler.reject(DioException(
                requestOptions: options,
                type: DioExceptionType.connectionError,
                message: '网络连接失败',
              ));
              return;
            }
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'unbound': true},
            ));
            return;
          }
          if (options.path == '/student-identity') {
            handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'identities': [
                  {
                    'provider_id': 'sylu_undergraduate',
                    'student_id': '2026000001',
                    'verified': true,
                    'verification_method': 'school_profile',
                  }
                ],
              },
            ));
            return;
          }
          if (options.path.startsWith('/academic-account-configs')) {
            handler.resolve(_configResponse(options));
            return;
          }
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'success': true},
          ));
        },
      ));
      final router = AcademicProviderRouterRepository(
        legacy: AcademicRepositoryImpl(
          local: JiaowuLocalDataSource(),
          legacy: LegacyServerDataSource(dio),
          source: AcademicSourceKind.legacy,
        ),
        registry: AcademicProviderRegistry([_TestProviderFactory()]),
        identityClient: AcademicIdentityClient(dio),
        configClient: AcademicAccountConfigClient(dio),
      );
      session = AcademicSessionController(repository: router);
      provider = EduProvider(dio)..setAcademicSessionController(session);
      addTearDown(() {
        provider.dispose();
        session.dispose();
        dio.close();
      });
    }

    Future<void> bindIdentity() async {
      await session.syncAppUser('test-app-user');
      const identity = AcademicIdentityKey(
        appUserId: 'test-app-user',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: '2026000001',
      );
      // 真实登录在提交身份时写入本机投影；这里先补齐再加载，模拟已绑定状态。
      await session.providerRouter!.accountStore!.commitIdentity(identity);
      final bindings = await session.providerRouter!.loadIdentityBindings();
      await session.selectProviderIdentity(bindings.first.toIdentity('test-app-user'));
    }

    test('解绑先撤销服务端可信身份，再提交云端配置删除，且不触发旧授权撤销',
        () async {
      initializeRouter();
      await bindIdentity();

      final result = await provider.unbind();
      expect(result.success, isTrue);

      final identityDeletes = requests
          .where((r) => r.path == '/student-identity' && r.method == 'DELETE')
          .toList();
      expect(identityDeletes, hasLength(1));
      expect(identityDeletes.single.data['provider_id'], 'sylu_undergraduate');
      expect(identityDeletes.single.data['student_id'], '2026000001');

      // 解绑内部异步触发配置同步；显式等待一轮后断言云端配置删除，
      // 并且发生在可信身份撤销之后。
      await session.providerRouter!.syncConfiguration();
      final configDeletes = requests
          .where((r) =>
              r.path == '/academic-account-configs/sylu_undergraduate' &&
              r.method == 'DELETE')
          .toList();
      expect(configDeletes, isNotEmpty);
      expect(requests.indexOf(identityDeletes.single),
          lessThan(requests.indexOf(configDeletes.first)));
      expect(requests.where((r) => r.path == '/edu/authorization'), isEmpty);
    });

    test('远端解绑失败时返回失败并保留本机身份，重试可成功', () async {
      initializeRouter();
      await bindIdentity();

      rejectIdentityUnbind = true;
      final failed = await provider.unbind();
      expect(failed.success, isFalse);
      expect(
        requests.where(
            (r) => r.path == '/student-identity' && r.method == 'DELETE'),
        hasLength(1),
      );
      // 本机身份与学号投影必须完整保留，用户可以直接重试。
      final store = session.providerRouter!.accountStore!;
      expect(store.entry(AcademicProviderId.syluUndergraduate)['student_id'],
          '2026000001');

      rejectIdentityUnbind = false;
      expect((await provider.unbind()).success, isTrue);
      expect(
        requests.where(
            (r) => r.path == '/student-identity' && r.method == 'DELETE'),
        hasLength(2),
      );
    });
  });
}

class _TestProviderFactory implements AcademicProviderFactory {
  _TestProviderFactory([this.id = AcademicProviderId.syluUndergraduate]);
  @override
  final AcademicProviderId id;
  @override
  AcademicProvider create(AcademicIdentityKey identity) =>
      _TestProvider(identity);
}

class _TestProvider implements AcademicProvider {
  _TestProvider(this.identity);
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
          '测试 Provider',
        ),
      );
  @override
  Future<void> restoreSession(ProviderSessionArtifact artifact) async {}
  @override
  Future<AcademicSessionProbeResult> probeSession() async =>
      AcademicSessionProbeResult(
          authenticated: true, confirmedStudentId: identity.studentId);
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
