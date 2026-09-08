import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;
import 'package:shenliyuan/features/academic/application/academic_login_coordinator.dart';
import 'package:shenliyuan/features/academic/application/academic_session_controller.dart';
import 'package:shenliyuan/features/academic/data/academic_account_config_client.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_adapters.dart';
import 'package:shenliyuan/features/academic/data/academic_provider_router_repository.dart';
import 'package:shenliyuan/features/academic/data/academic_repository_impl.dart';
import 'package:shenliyuan/features/academic/data/graduate/graduate_protocol_client.dart';
import 'package:shenliyuan/features/academic/domain/academic_captcha_recognizer.dart';
import 'package:shenliyuan/features/academic/domain/academic_data_source.dart';
import 'package:shenliyuan/features/academic/domain/academic_provider.dart';
import 'package:shenliyuan/features/academic/domain/academic_repository.dart';
import 'package:shenliyuan/features/academic/storage/academic_credential_store.dart';
import 'package:shenliyuan/features/academic/storage/academic_persistence_policy.dart';
import 'package:shenliyuan/features/academic/storage/local_academic_account_store.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import 'academic_identity_lifecycle_test.dart' show Secrets;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppPreferencesStore.setMockInitialValues({}));
  Future<_Harness> setup() async {
    final h = _Harness(await AppPreferencesStore.getInstance());
    addTearDown(h.close);
    await h.session.syncAppUser('1');
    return h;
  }

  test('本科直接本机登录，HK 断网仍成功，密码不出现在 HK 请求中', () async {
    final h = await setup();
    final result = await h.login('A', AcademicProviderId.syluUndergraduate);
    expect(result.isSuccess, true);
    expect(h.session.isAuthenticated, true);
    expect(h.router.accountStore!.identities.single.studentId, 'A');
    expect(h.sources.single.logins, 1);
    expect(h.gateways, isEmpty);
    await h.router.syncConfiguration();
    expect(
        h.requests.every((r) => r.path.startsWith('/academic-account-configs')),
        true);
    expect(h.requests.map((r) => r.data.toString()).join(),
        isNot(contains('password-secret')));
    expect((await h.credentials.readForIdentity(h.session.identity!))?.password,
        'password-secret');
  });

  test('研究生只走自己的验证码与资料协议，不调用本科登录', () async {
    final h = await setup();
    final waiting = await h.login('SAME', AcademicProviderId.syluGraduate);
    expect(waiting.needsCaptcha, true);
    expect(h.gateways.single.logins, 0);
    expect(h.sources, isEmpty);
    final result = await h.coordinator.continueLoginWithCaptcha(code: '1234');
    expect(result.isSuccess, true);
    expect(h.gateways.single.logins, 1);
    expect(h.session.identity!.providerId, AcademicProviderId.syluGraduate);
    expect(h.router.accountStore!.identities.single.studentId, 'SAME');
  });

  test('本科验证码续登调用本科 continuation，不重新提交初始登录', () async {
    final h = await setup();
    h.undergraduateCaptcha = true;
    final waiting = await h.login('A', AcademicProviderId.syluUndergraduate);
    expect(waiting.needsCaptcha, true);
    final result = await h.coordinator.continueLoginWithCaptcha(code: '9876');
    expect(result.isSuccess, true);
    expect(h.sources.single.logins, 1);
    expect(h.sources.single.continuations, 1);
  });

  test('换绑学校拒绝 B 后保留 A 的本机配置和运行时', () async {
    final h = await setup();
    await h.login('A', AcademicProviderId.syluUndergraduate);
    final old = h.session.identity;
    final result = await h.login('B', AcademicProviderId.syluUndergraduate,
        password: 'reject', change: true);
    expect(result.kind, AcademicLoginOutcomeKind.invalidCredentials);
    expect(h.session.identity, old);
    expect(h.session.isAuthenticated, true);
    expect(h.router.accountStore!.identities.single.studentId, 'A');
    expect((await h.credentials.readForIdentity(old!))?.password,
        'password-secret');
  });

  test('学校资料身份不一致时不提交本机配置也不同步新账号', () async {
    final h = await setup();
    h.mismatch = true;
    final result = await h.login('A', AcademicProviderId.syluUndergraduate);
    expect(result.isSuccess, false);
    expect(h.router.accountStore!.identities, isEmpty);
    expect(h.session.identity, isNull);
    expect(
        h.router.accountStore!
            .entry(AcademicProviderId.syluUndergraduate)['outbox'],
        isNull);
  });

  test('离线换绑 B 后重启仍选择 B，本科研究生相同学号也各自保存', () async {
    final h = await setup();
    await h.login('A', AcademicProviderId.syluUndergraduate);
    expect(
        (await h.login('B', AcademicProviderId.syluUndergraduate, change: true))
            .isSuccess,
        true);
    final undergraduate = h.session.identity!;
    await h.login('B', AcademicProviderId.syluGraduate, add: true);
    expect(
        (await h.coordinator.continueLoginWithCaptcha(code: '1234')).isSuccess,
        true);
    final graduate = h.session.identity!;
    expect(undergraduate.storageId, isNot(graduate.storageId));
    final restarted = _Harness(h.preferences);
    addTearDown(restarted.close);
    await restarted.session.syncAppUser('1');
    expect(restarted.session.identity, graduate);
    expect(LocalAcademicAccountStore('1', h.preferences).identities.toSet(),
        {undergraduate, graduate});
  });

  test('保存偏好期间切换 App 账号，凭据清理仍只作用于原登录身份', () async {
    final h = await setup();
    await h.login('A', AcademicProviderId.syluUndergraduate);
    final original = h.session.identity!;
    const other = AcademicIdentityKey(
        appUserId: '2',
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: 'A');
    await h.credentials.writeForIdentity(other,
        const AcademicCredential(studentId: 'A', password: 'other-password'));
    final blockedPreferences = _BlockedPreferenceStore();
    final coordinator = AcademicLoginCoordinator(
        controller: h.session,
        credentialStore: h.credentials,
        preferencesLoader: () async => h.preferences,
        persistencePolicy: AcademicPersistencePolicy(
            appUserId: '1',
            preferences: blockedPreferences,
            academicStore: null,
            scheduleStore: null));
    final login = coordinator.login(
        studentId: 'A',
        password: 'password-secret',
        saveCredentials: false,
        saveAcademicData: false);
    await blockedPreferences.started.future;
    final switchUser = h.session.syncAppUser('2');
    blockedPreferences.release.complete();
    expect((await login).kind, AcademicLoginOutcomeKind.contextChanged);
    await switchUser;
    expect(await h.credentials.readForIdentity(original), isNull);
    expect((await h.credentials.readForIdentity(other))?.password,
        'other-password');
    expect(h.router.accountStore!.identities, isEmpty);
  });

  test('新设备配置只补全目标学号，尚无凭据时不会向学校提交空密码', () async {
    final h = await setup();
    await h.router.accountStore!.mergeSnapshot({
      'provider_id': 'sylu_graduate',
      'student_id': 'G',
      'state': 'active',
      'revision': 3
    });
    final outcome = await h.coordinator.ensureAuthenticated();
    expect(h.session.identity?.studentId, 'G');
    expect(h.session.identity?.providerId, AcademicProviderId.syluGraduate);
    expect(outcome.kind, AcademicLoginOutcomeKind.credentialsRequired);
    expect(h.gateways.single.logins, 0);
  });
}

class _Harness {
  _Harness(this.preferences) {
    dio.interceptors.add(InterceptorsWrapper(onRequest: (r, h) {
      requests.add(r);
      h.reject(DioException(
          requestOptions: r, type: DioExceptionType.connectionError));
    }));
    final empty = _Source();
    router = AcademicProviderRouterRepository(
        legacy: AcademicRepositoryImpl(
            local: empty, legacy: empty, source: AcademicSourceKind.legacy),
        registry: AcademicProviderRegistry([
          _UndergraduateFactory((identity) {
            final s =
                _Source(captcha: undergraduateCaptcha, mismatch: mismatch);
            sources.add(s);
            return UndergraduateAcademicProvider(identity: identity, source: s);
          }),
          GraduateAcademicProviderFactory(
              gatewayFactory: () {
                final g = _Gateway();
                gateways.add(g);
                return g;
              },
              captchaRecognizer: const ManualAcademicCaptchaRecognizer()),
        ]),
        configClient: AcademicAccountConfigClient(dio));
    session = AcademicSessionController(repository: router);
    coordinator = AcademicLoginCoordinator(
        controller: session,
        credentialStore: credentials,
        silentCaptcha: false,
        preferencesLoader: () async => preferences,
        persistencePolicy: AcademicPersistencePolicy(
            appUserId: '1',
            preferences: preferences,
            academicStore: null,
            scheduleStore: null));
  }
  final AppPreferencesStore preferences;
  final dio = Dio();
  final requests = <RequestOptions>[];
  final sources = <_Source>[];
  final gateways = <_Gateway>[];
  final credentials = PlatformAcademicCredentialStore(secretStore: Secrets());
  late final AcademicProviderRouterRepository router;
  late final AcademicSessionController session;
  late final AcademicLoginCoordinator coordinator;
  bool undergraduateCaptcha = false;
  bool mismatch = false;
  Future<AcademicLoginOutcome> login(
          String student, AcademicProviderId provider,
          {String password = 'password-secret',
          bool change = false,
          bool add = false}) =>
      coordinator.login(
          studentId: student,
          password: password,
          providerId: provider,
          changeIdentity: change,
          addIdentity: add,
          saveCredentials: true,
          saveAcademicData: false);
  void close() {
    session.dispose();
    router.close();
    dio.close();
  }
}

class _UndergraduateFactory implements AcademicProviderFactory {
  _UndergraduateFactory(this.factory);
  final AcademicProvider Function(AcademicIdentityKey) factory;
  @override
  AcademicProviderId get id => AcademicProviderId.syluUndergraduate;
  @override
  AcademicProvider create(AcademicIdentityKey identity) => factory(identity);
}

class _Source implements AcademicDataSource {
  _Source({this.captcha = false, this.mismatch = false});
  final bool captcha;
  final bool mismatch;
  int logins = 0;
  int continuations = 0;
  String? student;
  SessionState state = SessionState.unauthenticated;
  @override
  String get sourceName => "本机测试教务";
  @override
  SessionState get sessionState => state;
  @override
  String? get studentId => student;
  @override
  Future<LoginResult> login(
      {required String studentId, required String password}) async {
    logins++;
    student = studentId;
    if (password == 'reject') return const InvalidCredentials();
    if (captcha) return const CaptchaRequired();
    state = SessionState.authenticated;
    return LoginSuccess(studentId: studentId, cookieNames: const {});
  }

  @override
  Future<LoginResult> continueLoginWithCaptcha({required String code}) async {
    continuations++;
    state = SessionState.authenticated;
    return LoginSuccess(studentId: student!, cookieNames: const {});
  }

  @override
  Future<CaptchaChallenge> getCaptchaChallenge() async =>
      CaptchaChallenge(imageBytes: Uint8List.fromList([1]));
  @override
  Future<StudentProfile> getProfile() async => StudentProfile(
      name: '测试',
      grade: '',
      college: '',
      major: '',
      studentId: mismatch ? 'WRONG' : student);
  @override
  Future<void> resetSession() async {
    state = SessionState.unauthenticated;
  }

  @override
  Future<void> restoreSession() async {}
  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Gateway implements GraduateProtocolGateway {
  String? student;
  int logins = 0;
  @override
  Future<GraduateCaptcha> prepareLogin() async =>
      GraduateCaptcha(Uint8List.fromList([1]), challengeId: 'g-captcha');
  @override
  Future<void> login(
      {required String studentId,
      required String password,
      required String captchaCode}) async {
    logins++;
    student = studentId;
  }

  @override
  Future<GraduateProfile> fetchProfile() async =>
      GraduateProfile(studentId: student);
  @override
  Future<GraduateSessionState> probe() async =>
      GraduateSessionState(authenticated: student != null, studentId: student);
  @override
  Future<void> reset() async {
    student = null;
  }

  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _BlockedPreferenceStore extends MemoryPreferencesStore {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<bool> setBool(String key, bool value) async {
    if (key.startsWith('academic_save_credentials_') && !value) {
      started.complete();
      await release.future;
    }
    return super.setBool(key, value);
  }
}
