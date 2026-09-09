import '../storage/academic_connection_store.dart';
import 'academic_identity_lifecycle_coordinator.dart';
import 'dart:async';

import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../../../platform/contracts/preferences_store.dart';
import '../storage/academic_credential_store.dart';
import '../storage/academic_persistence_policy.dart';
import '../storage/academic_persistence_gate.dart';
import '../storage/academic_storage_preferences.dart';
import '../domain/academic_repository.dart';
import '../domain/academic_failure.dart';
import '../domain/academic_provider.dart';
import '../domain/academic_captcha_submission_policy.dart';
import '../domain/academic_captcha_recognizer.dart';
import '../data/academic_identity_client.dart';
import '../../campus_data/storage/academic_cache_store.dart';
import '../../campus_data/storage/account_scoped_snapshot_store.dart';
import '../../campus_data/storage/schedule_cache_store.dart';
import 'academic_session_controller.dart';

enum AcademicLoginOutcomeKind {
  success,
  captchaRequired,
  credentialsRequired,
  invalidCredentials,
  challengeRejected,
  accountRejected,
  accountRestricted,
  identityMismatch,
  identityUnverified,
  authRejectedAmbiguous,
  networkFailure,
  profileFailure,
  contextChanged,
  failure,
}

final class AcademicLoginOutcome {
  const AcademicLoginOutcome({
    required this.kind,
    this.message,
    this.saveCredentialWarning = false,
  });

  final AcademicLoginOutcomeKind kind;
  final String? message;
  final bool saveCredentialWarning;

  bool get isSuccess => kind == AcademicLoginOutcomeKind.success;
  bool get needsCaptcha => kind == AcademicLoginOutcomeKind.captchaRequired;
}

final class _PendingAcademicLogin {
  const _PendingAcademicLogin({
    required this.appUserId,
    required this.generation,
    required this.credentialEpoch,
    required this.credential,
    required this.saveCredentials,
    required this.saveAcademicData,
  });

  final String appUserId;
  final int generation;
  final int credentialEpoch;
  final AcademicCredential credential;
  final bool saveCredentials;
  final bool saveAcademicData;
}

/// 连接凭据存储、本机资料策略和运行时学校 Session 的协调层。
///
/// SessionController 不接触 Secure Store；验证码阶段的密码只保留在这里的
/// pending 对象中，直到学校最终返回登录成功。
final class AcademicLoginCoordinator {
  AcademicLoginCoordinator({
    required this.controller,
    AcademicCredentialStore? credentialStore,
    this.identityClient,
    Future<AppPreferencesStore> Function()? preferencesLoader,
    this.persistencePolicy,
    this.captchaSubmissionPolicy = const AcademicCaptchaSubmissionPolicy(),
    this.silentCaptcha = true,
    this.bindingRetryDelay = const Duration(seconds: 30),
    AcademicCaptchaRecognizer Function()? identityCaptchaRecognizerFactory,
  })  : credentialStore = credentialStore ?? PlatformAcademicCredentialStore(),
        _preferencesLoader =
            preferencesLoader ?? AppPreferencesStore.getInstance {
    controller.disposeReadSessionGate?.call();
    controller.disposeReadSessionGate = dispose;
    controller.readSessionGate = () async {
      final generation = controller.contextGeneration;
      final result = await ensureAuthenticated();
      if (!result.isSuccess &&
          controller.isCurrentContext(generation: generation)) {
        controller.recordReadSessionFailure(AcademicFailure(
          kind: switch (result.kind) {
            AcademicLoginOutcomeKind.credentialsRequired =>
              AcademicFailureKind.localCredentialRequired,
            AcademicLoginOutcomeKind.invalidCredentials =>
              AcademicFailureKind.invalidCredentials,
            AcademicLoginOutcomeKind.networkFailure =>
              AcademicFailureKind.network,
            _ => controller.failure?.kind ?? AcademicFailureKind.unexpected,
          },
          message:
              result.message ?? controller.failure?.message ?? '教务恢复暂未完成，请稍后重试',
          code: result.kind == AcademicLoginOutcomeKind.credentialsRequired
              ? 'credentials_required'
              : controller.failure?.code ?? 'ACADEMIC_SESSION_NOT_READY',
        ));
      }
      return result.isSuccess;
    };
  }

  final AcademicSessionController controller;
  final AcademicCredentialStore credentialStore;
  final AcademicIdentityClient? identityClient;
  AcademicIdentityClient? get _identityClient =>
      identityClient ?? controller.providerRouter?.identityClient;
  final Map<AcademicIdentityKey, Future<String?>> _bindingSyncs = {};
  final Set<AcademicIdentityKey> _syncedIdentities = {};
  final Map<AcademicIdentityKey, DateTime> _bindingAttempts = {};
  final Duration bindingRetryDelay;
  Timer? _bindingRetry;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _bindingRetry?.cancel();
  }

  Future<String> bindingSyncState() async {
    final identity = controller.identity;
    if (identity == null) return 'none';
    return AcademicConnectionStore(identity, await _preferencesLoader())
        .bindingSyncState;
  }

  final Future<AppPreferencesStore> Function() _preferencesLoader;
  final AcademicPersistencePolicy? persistencePolicy;
  final AcademicCaptchaSubmissionPolicy captchaSubmissionPolicy;
  final bool silentCaptcha;
  Future<AcademicLoginOutcome>? _ensureInFlight;
  _PendingAcademicLogin? _pending;
  AcademicIdentityKey? _replacedIdentity;

  AcademicIdentityChallenge? get pendingIdentityChallenge => null;

  Future<void>? _cleanupInFlight;

  Future<void> resumePendingCleanup() {
    final running = _cleanupInFlight;
    if (running != null) return running;
    final user = controller.appUserId;
    final operation = () async {
      if (user == null) return;
      final preferences = await _preferencesLoader();
      final accountStore = controller.providerRouter?.accountStore;
      if (controller.appUserId != user) return;
      for (final identity in {
        ...AcademicConnectionStore.pendingIdentities(preferences, user),
        ...?accountStore?.pendingCleanup
      }) {
        if (controller.appUserId != user) return;
        try {
          await AcademicIdentityLifecycleCoordinator(
                  controller: controller,
                  preferences: preferences,
                  credentials: credentialStore
                          is IdentityScopedAcademicCredentialStore
                      ? credentialStore as IdentityScopedAcademicCredentialStore
                      : null)
              .clearLocalIdentity(identity);
          await accountStore?.acknowledgeCleanup(identity);
        } catch (_) {
          // 保留 pending；启动不因磁盘或安全存储暂不可用而中断。
        }
      }
    }();
    _cleanupInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_cleanupInFlight, operation)) _cleanupInFlight = null;
    });
  }

  void cancelIdentityVerification() {
    controller.dismissCaptchaChallenge();
  }

  /// 取消临时认证时恢复原本机账号，已配置账号仍可稍后重新连接。
  Future<AcademicLoginOutcome> cancelLogin() async {
    cancelIdentityVerification();
    _pending = null;
    controller.dismissCaptchaChallenge();
    try {
      if (controller.providerRouter?.isProvisional == true) {
        await controller.cancelLocalConnection();
      } else {
        await controller.resetSession();
      }
      return const AcademicLoginOutcome(kind: AcademicLoginOutcomeKind.success);
    } catch (_) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '教务账号已保留，本机会话清理未完成，请重试',
      );
    }
  }

  Future<AcademicCredential?> readSavedCredential() async {
    final appUserId = controller.appUserId;
    if (appUserId == null) return null;
    final identity = controller.identity;
    if (identity != null &&
        credentialStore is IdentityScopedAcademicCredentialStore) {
      return (credentialStore as IdentityScopedAcademicCredentialStore)
          .readForIdentity(identity);
    }
    return credentialStore.read(appUserId);
  }

  Future<AcademicCredential?> readEnabledCredential() async {
    final provider = controller.providerId;
    if (provider != null &&
        controller.providerRouter?.accountStore?.rejected(provider) == true) {
      return null;
    }
    final preferences = await _loadPreferences();
    if (!preferences.saveCredentials) return null;
    return readSavedCredential();
  }

  Future<AcademicStoragePreferences> loadPreferences(
          {AcademicProviderId? providerId}) =>
      _loadPreferences(providerId: providerId);

  Future<bool> hasSavedCredential() async =>
      (await readEnabledCredential()) != null;

  Future<AcademicLoginOutcome> login({
    required String studentId,
    String password = '',
    required bool saveCredentials,
    required bool saveAcademicData,
    bool useSavedCredential = false,
    AcademicProviderId? providerId,
    bool changeIdentity = false,
    bool addIdentity = false,
  }) async {
    try {
      if (controller.hasBoundIdentity && !addIdentity && !changeIdentity) {
        await controller.allowDeviceConnection();
      }
      final result = await _loginOnce(
          studentId: studentId,
          password: password,
          saveCredentials: saveCredentials,
          saveAcademicData: saveAcademicData,
          useSavedCredential: useSavedCredential,
          providerId: providerId,
          changeIdentity: changeIdentity,
          addIdentity: addIdentity);
      return await _completeCaptchaSilently(result);
    } catch (_) {
      return AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.failure,
          message: controller.hasBoundIdentity
              ? '教务账号已配置，本机设置未完成，请重试连接'
              : '教务身份操作未完成，请重试');
    }
  }

  /// 每个认证阶段最多提交两次；刷新后的第三张图只留给人工。
  Future<AcademicLoginOutcome> _completeCaptchaSilently(
      AcademicLoginOutcome outcome) async {
    if (!silentCaptcha) return outcome;
    var attempts = 0;
    while (outcome.needsCaptcha && attempts < 2) {
      if (controller.providerId != AcademicProviderId.syluGraduate) {
        break;
      }
      final code = controller.captchaSuggestion;
      final confidence = controller.captchaSuggestionConfidence;
      if (code == null ||
          !RegExp(r'^\d{4}$').hasMatch(code) ||
          confidence == null ||
          !confidence.isFinite ||
          confidence < .70) {
        break;
      }
      final pending = _pending;
      attempts++;
      outcome = await continueLoginWithCaptcha(code: code);
      final rejected =
          controller.failure?.kind == AcademicFailureKind.challengeRejected ||
              controller.failure?.kind == AcademicFailureKind.captchaExpired;
      if (!rejected || pending == null) break;
      if (!controller.isCurrentContext(
          generation: pending.generation, appUserId: pending.appUserId)) {
        return const AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.contextChanged);
      }
      outcome = await _login(
          appUserId: pending.appUserId,
          studentId: pending.credential.studentId,
          password: pending.credential.password,
          saveCredentials: pending.saveCredentials,
          saveAcademicData: pending.saveAcademicData,
          useSavedCredential: false);
    }
    return outcome;
  }

  Future<AcademicLoginOutcome> _loginOnce({
    required String studentId,
    String password = '',
    required bool saveCredentials,
    required bool saveAcademicData,
    bool useSavedCredential = false,
    AcademicProviderId? providerId,
    bool changeIdentity = false,
    bool addIdentity = false,
  }) async {
    final appUserId = controller.appUserId;
    if (appUserId == null || appUserId.isEmpty) {
      return Future.value(const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '请先登录 APP',
      ));
    }
    if (controller.providerRouter != null &&
        (!controller.hasBoundIdentity || addIdentity || changeIdentity)) {
      if (providerId == null) {
        return Future.value(const AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.failure, message: '请选择本科或研究生教务'));
      }
      return _beginLocalLogin(
          appUserId: appUserId,
          providerId: providerId,
          studentId: studentId,
          password: password,
          saveCredentials: saveCredentials,
          saveAcademicData: saveAcademicData);
    }
    return _login(
      appUserId: appUserId,
      studentId: studentId,
      password: password,
      saveCredentials: saveCredentials,
      saveAcademicData: saveAcademicData,
      useSavedCredential: useSavedCredential,
    );
  }

  Future<void> refreshCaptcha() async {
    final pending = _pending;
    final operation = controller.refreshCaptcha();
    final generation = controller.contextGeneration;
    await operation;
    if (pending == null ||
        !controller.isCurrentContext(
            generation: generation, appUserId: pending.appUserId)) {
      return;
    }
    _pending = _PendingAcademicLogin(
        appUserId: pending.appUserId,
        generation: generation,
        credentialEpoch: pending.credentialEpoch,
        credential: pending.credential,
        saveCredentials: pending.saveCredentials,
        saveAcademicData: pending.saveAcademicData);
  }

  Future<AcademicLoginOutcome> continueLoginWithCaptcha(
      {required String code}) async {
    try {
      return await _continueLoginWithCaptcha(code: code);
    } catch (_) {
      return AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.failure,
          message: controller.hasBoundIdentity
              ? '教务账号已配置，本机设置未完成，请重试连接'
              : '验证码操作未完成，请重试');
    }
  }

  Future<AcademicLoginOutcome> _continueLoginWithCaptcha({
    required String code,
  }) async {
    final pending = _pending;
    if (pending == null ||
        !controller.isCurrentContext(
          generation: pending.generation,
          appUserId: pending.appUserId,
        )) {
      _pending = null;
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.contextChanged,
        message: '教务账号上下文已切换，请重新登录',
      );
    }
    final result = await controller.continueLoginWithCaptcha(code: code);
    return _handleLoginResult(
      result,
      appUserId: pending.appUserId,
      generation: pending.generation,
      credentialEpoch: pending.credentialEpoch,
      credential: pending.credential,
      saveCredentials: pending.saveCredentials,
      saveAcademicData: pending.saveAcademicData,
    );
  }

  // 学校会话已经在本机探活；HK 只登记最小绑定声明，不访问学校。
  Future<String?> _syncLocalBinding({bool force = false}) async {
    final identity = controller.identity;
    final client = _identityClient;
    if (_disposed || identity == null || client == null) {
      return null;
    }
    final generation = controller.contextGeneration;
    final running = _bindingSyncs[identity];
    if (running != null) return running;
    if (!force && _syncedIdentities.contains(identity)) return null;
    final last = _bindingAttempts[identity];
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 30)) {
      return null;
    }
    _bindingAttempts[identity] = DateTime.now();
    final operation = () async {
      try {
        final store =
            AcademicConnectionStore(identity, await _preferencesLoader());
        bool current() =>
            !_disposed &&
            controller.identity == identity &&
            controller.isCurrentContext(
                generation: generation, appUserId: identity.appUserId);
        if (!current()) return null;
        if (!store.connected) {
          await store.setBindingSyncState('none');
          return null;
        }
        // 已通过本机认证的待同步声明可在学校离线时补发，不再提交学校密码。
        if (!controller.isAuthenticated &&
            store.bindingSyncState != 'pending') {
          return null;
        }
        await store.setBindingSyncState('pending');
        if (!current() || !store.connected) return null;
        await client.bindLocal(identity);
        if (!current() || !store.connected) {
          return null;
        }
        await controller.providerRouter?.onIdentityVerified?.call();
        if (!current() || !store.connected) return null;
        await store.setBindingSyncState('bound');
        _syncedIdentities.add(identity);
        _bindingRetry?.cancel();
        return null;
      } catch (_) {
        if (!_disposed &&
            controller.identity == identity &&
            controller.isCurrentContext(
                generation: generation, appUserId: identity.appUserId)) {
          _bindingRetry?.cancel();
          _bindingRetry = Timer(bindingRetryDelay, () {
            if (!_disposed &&
                controller.identity == identity &&
                controller.isCurrentContext(
                    generation: generation, appUserId: identity.appUserId)) {
              unawaited(_syncLocalBinding(force: true));
            }
          });
        }
        return '教务已在本机连接，学生身份尚未同步；联网后会重试';
      }
    }();
    _bindingSyncs[identity] = operation;
    try {
      return await operation;
    } finally {
      _bindingSyncs.remove(identity);
    }
  }

  Future<AcademicLoginOutcome> _beginLocalLogin({
    required String appUserId,
    required AcademicProviderId providerId,
    required String studentId,
    required String password,
    required bool saveCredentials,
    required bool saveAcademicData,
  }) async {
    if (studentId.trim().isEmpty || password.isEmpty) {
      return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.credentialsRequired,
          message: '请输入教务学号和密码');
    }
    final router = controller.providerRouter!;
    await router.loadIdentityBindings();
    await resumePendingCleanup();
    if (controller.appUserId != appUserId) {
      return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.contextChanged);
    }
    final next = AcademicIdentityKey(
        appUserId: appUserId,
        providerId: providerId,
        studentId: studentId.trim());
    if (router.accountStore!.pendingCleanup.contains(next) ||
        AcademicConnectionStore(next, await _preferencesLoader())
            .cleanupPending) {
      return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.failure,
          message: '此学号的旧资料尚未清理完成，请稍后重试');
    }
    final previous = router.accountStore!.identities
        .where((i) => i.providerId == providerId)
        .firstOrNull;
    _replacedIdentity = previous != next ? previous : null;
    await controller.beginLocalConnection(next);
    return _login(
        appUserId: appUserId,
        studentId: studentId,
        password: password,
        saveCredentials: saveCredentials,
        saveAcademicData: saveAcademicData,
        useSavedCredential: false);
  }

  int? _warmUpGeneration;
  final Map<int, Future<void>> _warmUps = {};

  Future<void> warmUp() async {
    await controller.waitForAccountContextReady();
    final generation = controller.contextGeneration;
    if (controller.appUserId == null || _warmUpGeneration == generation) return;
    final running = _warmUps[generation];
    if (running != null) return running;
    final operation = () async {
      final outcome = await ensureAuthenticated();
      if (controller.isCurrentContext(generation: generation) &&
          (outcome.isSuccess ||
              outcome.kind == AcademicLoginOutcomeKind.credentialsRequired ||
              outcome.kind == AcademicLoginOutcomeKind.invalidCredentials ||
              outcome.needsCaptcha)) {
        _warmUpGeneration = generation;
      }
      await _syncLocalBinding();
    }();
    _warmUps[generation] = operation;
    try {
      await operation;
    } finally {
      _warmUps.remove(generation);
    }
  }

  Future<AcademicLoginOutcome> ensureAuthenticated({
    bool allowSavedCredential = true,
  }) async {
    await controller.waitForAccountContextReady();
    if (controller.isAuthenticated) {
      unawaited(_syncLocalBinding());
      return Future.value(const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.success,
      ));
    }
    final current = _ensureInFlight;
    if (current != null) return current;
    final operation =
        _ensureAuthenticated(allowSavedCredential: allowSavedCredential);
    _ensureInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_ensureInFlight, operation)) _ensureInFlight = null;
    });
  }

  Future<AcademicLoginOutcome> _ensureAuthenticated({
    required bool allowSavedCredential,
  }) async {
    final requestGeneration = controller.contextGeneration;
    final requestUser = controller.appUserId;
    if (controller.providerRouter != null && !controller.hasBoundIdentity) {
      await controller.ensureAuthenticated();
      if (!controller.isCurrentContext(
          generation: requestGeneration, appUserId: requestUser)) {
        return const AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.contextChanged);
      }
      if (!controller.hasBoundIdentity) {
        return AcademicLoginOutcome(
            kind: controller.failure == null
                ? AcademicLoginOutcomeKind.credentialsRequired
                : AcademicLoginOutcomeKind.failure,
            message: controller.failure?.message ?? '请先添加教务账号');
      }
    }

    if (!await controller.remoteAccessAllowed()) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '本机教务已断开，请先重新连接',
      );
    }
    if (controller.pendingAcademicChallenge != null) {
      // 课表等读取入口可能接手到上一个界面已经准备好的
      // Provider challenge。它仍属于同一次登录，应先继续静默识别
      // 与有限重试，不能绕过协调器直接弹出人工验证码。
      return _completeCaptchaSilently(
        const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.captchaRequired,
        ),
      );
    }
    if (controller.sourceKind == AcademicSourceKind.legacy) {
      final generation = controller.contextGeneration;
      final appUserId = controller.appUserId;
      try {
        // 服务端绑定不依赖手机保存密码，冷启动和短暂断网后先尝试恢复已有授权。
        await controller.restoreSession();
        if (!controller.isCurrentContext(
            generation: generation, appUserId: appUserId)) {
          return const AcademicLoginOutcome(
              kind: AcademicLoginOutcomeKind.contextChanged);
        }
        return AcademicLoginOutcome(
          kind: controller.isAuthenticated
              ? AcademicLoginOutcomeKind.success
              : AcademicLoginOutcomeKind.credentialsRequired,
          message: controller.isAuthenticated ? null : '请先绑定教务账号',
        );
      } catch (error) {
        final failure = AcademicFailure.fromException(error);
        return AcademicLoginOutcome(
          kind: failure.kind == AcademicFailureKind.network
              ? AcademicLoginOutcomeKind.networkFailure
              : AcademicLoginOutcomeKind.failure,
          message: failure.message,
        );
      }
    }
    // 先恢复学校会话；网络与协议故障不能被解释成需要再次提交密码。
    if (await controller.ensureAuthenticated()) {
      unawaited(_syncLocalBinding());
      return const AcademicLoginOutcome(kind: AcademicLoginOutcomeKind.success);
    }
    if (!controller.isCurrentContext(
        generation: requestGeneration, appUserId: requestUser)) {
      return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.contextChanged);
    }
    final restoreFailure = controller.failure;
    if (restoreFailure != null &&
        restoreFailure.kind != AcademicFailureKind.sessionExpired &&
        restoreFailure.kind != AcademicFailureKind.unauthenticated &&
        restoreFailure.kind != AcademicFailureKind.localCredentialRequired) {
      return AcademicLoginOutcome(
        kind: restoreFailure.kind == AcademicFailureKind.network
            ? AcademicLoginOutcomeKind.networkFailure
            : AcademicLoginOutcomeKind.failure,
        message: restoreFailure.message,
      );
    }
    if (!allowSavedCredential) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.credentialsRequired,
        message: '请输入教务账号和密码',
      );
    }
    final provider = controller.providerId;
    if (provider != null &&
        controller.providerRouter?.accountStore?.rejected(provider) == true) {
      return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.invalidCredentials,
          message: '学校已拒绝当前保存的密码，请更新密码');
    }
    AcademicCredential? saved;
    try {
      saved = await readEnabledCredential();
    } catch (_) {
      return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.failure, message: '本机安全存储暂不可用，请稍后重试');
    }
    if (saved == null) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.credentialsRequired,
        message: '请先输入教务账号和密码',
      );
    }
    final prefs = await _loadPreferences();
    if (!controller.isCurrentContext(
        generation: requestGeneration, appUserId: requestUser)) {
      return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.contextChanged);
    }
    var outcome = await _login(
      appUserId: controller.appUserId!,
      studentId: saved.studentId,
      password: saved.password,
      saveCredentials: true,
      saveAcademicData: prefs.saveAcademicData,
      useSavedCredential: false,
    );
    return _completeCaptchaSilently(outcome);
  }

  Future<AcademicLoginOutcome> _login({
    required String appUserId,
    required String studentId,
    required String password,
    required bool saveCredentials,
    required bool saveAcademicData,
    required bool useSavedCredential,
  }) async {
    var actualPassword = password;
    var actualStudentId = studentId.trim();
    if (useSavedCredential && actualPassword.isEmpty) {
      final saved = await _readCredentialForCurrentIdentity(appUserId);
      if (saved == null || saved.studentId != actualStudentId) {
        return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.credentialsRequired,
          message: '请重新输入教务密码',
        );
      }
      actualPassword = saved.password;
    }
    if (actualStudentId.isEmpty || actualPassword.isEmpty) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.credentialsRequired,
        message: '请输入教务学号和密码',
      );
    }

    final generation = controller.contextGeneration;
    final credentialEpoch = controller.providerRouter?.accountStore
            ?.epoch(controller.providerId!) ??
        0;
    final result = await controller.login(
      studentId: actualStudentId,
      password: actualPassword,
    );
    return _handleLoginResult(
      result,
      appUserId: appUserId,
      generation: generation,
      credentialEpoch: credentialEpoch,
      credential: AcademicCredential(
        studentId: actualStudentId,
        password: actualPassword,
      ),
      saveCredentials: saveCredentials,
      saveAcademicData: saveAcademicData,
    );
  }

  Future<AcademicLoginOutcome> _handleLoginResult(
    LoginResult result, {
    required String appUserId,
    required int generation,
    required int credentialEpoch,
    required AcademicCredential credential,
    required bool saveCredentials,
    required bool saveAcademicData,
  }) async {
    if (!controller.isCurrentContext(
      generation: generation,
      appUserId: appUserId,
    )) {
      _pending = null;
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.contextChanged,
        message: '教务账号上下文已切换，已丢弃本次登录结果',
      );
    }

    switch (result) {
      case CaptchaRequired(:final message):
        _pending = _PendingAcademicLogin(
          appUserId: appUserId,
          generation: generation,
          credentialEpoch: credentialEpoch,
          credential: credential,
          saveCredentials: saveCredentials,
          saveAcademicData: saveAcademicData,
        );
        return AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.captchaRequired,
          message: message,
        );
      case InvalidCredentials(:final message):
        _pending = null;
        final provider = controller.providerId;
        if (provider != null &&
            controller.providerRouter?.isProvisional != true) {
          await controller.providerRouter?.accountStore
              ?.reject(provider, credentialEpoch);
        }
        await controller.cancelLocalConnection();
        return AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.invalidCredentials,
          message: message,
        );
      case NetworkUnavailable(:final message):
        _pending = null;
        await controller.cancelLocalConnection();
        return AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.networkFailure,
          message: message,
        );
      case LoginSuccess():
        _pending = null;
        if (controller.providerRouter?.isProvisional == true &&
            !controller.isProfileLoaded) {
          await controller.cancelLocalConnection();
          return const AcademicLoginOutcome(
              kind: AcademicLoginOutcomeKind.profileFailure,
              message: '学校身份资料未确认，请重试连接');
        }
        final outcome = await controller.commit(() => _finalizeSuccess(
              generation: generation,
              appUserId: appUserId,
              credential: credential,
              saveCredentials: saveCredentials,
              saveAcademicData: saveAcademicData,
            ));
        return outcome;
      case CaptchaExpired(:final message):
        return AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.challengeRejected, message: message);
      case LoginPageChanged(:final message):
        _pending = null;
        await controller.cancelLocalConnection();
        return AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.failure,
          message: message,
        );
    }
  }

  Future<AcademicLoginOutcome> _finalizeSuccess({
    required int generation,
    required String appUserId,
    required AcademicCredential credential,
    required bool saveCredentials,
    required bool saveAcademicData,
  }) async {
    bool current() => controller.isCurrentContext(
        generation: generation, appUserId: appUserId);
    const changed =
        AcademicLoginOutcome(kind: AcademicLoginOutcomeKind.contextChanged);
    if (!current()) return changed;
    var saveWarning = false;
    final router = controller.providerRouter;
    // 写入跨越异步边界，收尾只操作本次身份与 Store，避免切号后误清理。
    final accountStore = router?.accountStore;
    final identity = controller.identity;
    if (router != null && identity != null) {
      // 先可靠记录本机目标和同步意图，云端请求永远不在成功判定路径。
      try {
        await accountStore!.commitIdentity(identity);
      } catch (_) {
        await controller.cancelLocalConnection();
        return const AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.failure,
            message: '学校已连接，但本机账号未能保存，请重试');
      }
      if (!current()) return changed;
      router.commitProvisional();
      unawaited(router.syncConfiguration());
    }
    // 服务端模式不读取或修改本机密码，资料缓存仍按独立策略处理。
    if (controller.sourceKind == AcademicSourceKind.local) {
      AcademicStoragePreferences? preferences;
      try {
        preferences =
            persistencePolicy?.preferences ?? await _loadPreferences();
        if (!current()) return changed;
        if (saveCredentials) {
          await _writeCredentialForIdentity(appUserId, identity, credential);
          await preferences.setSaveCredentials(true);
        } else {
          await preferences.setSaveCredentials(false);
          await _deleteCredentialForIdentity(appUserId, identity);
        }
      } catch (_) {
        if (!current()) return changed;
        saveWarning = true;
        // 用户已明确选择加密保存，偏好写入失败不能连带擦除新旧密码。
        // 只有显式取消保存时关闭自动使用；密码删除由上面的显式分支执行。
        if (!saveCredentials) {
          try {
            preferences ??=
                persistencePolicy?.preferences ?? await _loadPreferences();
            await preferences.setSaveCredentials(false);
          } catch (_) {}
        }
      }
    }

    if (!current()) return changed;
    try {
      final policy = persistencePolicy ??
          await _createPersistencePolicy(
            appUserId: appUserId,
            sourceAccountId: controller.studentId ?? credential.studentId,
          );
      if (!current()) return changed;
      if (saveAcademicData) {
        await policy.enable();
      } else {
        await policy.disableAndClear();
      }
    } catch (_) {
      // 登录成功不能被资料偏好或清理异常回滚；策略会保留 cleanup_pending。
      saveWarning = true;
    }

    if (current() && identity != null) {
      try {
        await controller.persistCurrentSession();
      } catch (_) {
        saveWarning = true;
      }
      final old = _replacedIdentity;
      _replacedIdentity = null;
      if (old != null &&
          old != identity &&
          old.appUserId == appUserId &&
          old.providerId == identity.providerId) {
        try {
          await AcademicIdentityLifecycleCoordinator(
                  controller: controller,
                  preferences: await _preferencesLoader(),
                  credentials: credentialStore
                          is IdentityScopedAcademicCredentialStore
                      ? credentialStore as IdentityScopedAcademicCredentialStore
                      : null)
              .clearLocalIdentity(old);
          await accountStore?.acknowledgeCleanup(old);
        } catch (_) {
          saveWarning = true;
        }
      }
    }
    if (!current()) return changed;
    final bindingWarning = await _syncLocalBinding(force: true);
    if (!current()) return changed;
    return AcademicLoginOutcome(
      kind: AcademicLoginOutcomeKind.success,
      message: bindingWarning ?? (saveWarning ? '已登录，但本机保存设置未完全生效' : null),
      saveCredentialWarning: saveWarning,
    );
  }

  Future<AcademicStoragePreferences> _loadPreferences(
      {AcademicProviderId? providerId}) async {
    final appUserId = controller.appUserId ?? '';
    try {
      final preferences = AcademicStoragePreferences(
        appUserId: appUserId,
        identity: providerId == null
            ? controller.identity
            : AcademicIdentityKey(
                appUserId: appUserId,
                providerId: providerId,
                studentId: controller.identity?.providerId == providerId
                    ? controller.identity!.studentId
                    : '_preference'),
        store: await _preferencesLoader(),
      );
      await preferences.migrateLegacyPreferences();
      return preferences;
    } catch (_) {
      // 偏好服务暂时不可用时仍允许手动登录；保存策略会在真正写入时给出警告。
      return AcademicStoragePreferences(
        appUserId: appUserId,
        identity: providerId == null
            ? controller.identity
            : AcademicIdentityKey(
                appUserId: appUserId,
                providerId: providerId,
                studentId: controller.identity?.providerId == providerId
                    ? controller.identity!.studentId
                    : '_preference'),
        store: MemoryPreferencesStore(),
      );
    }
  }

  Future<AcademicPersistencePolicy> _createPersistencePolicy({
    required String appUserId,
    required String sourceAccountId,
  }) async {
    final prefs = await _preferencesLoader();
    final providerId = controller.providerId;
    final identity = controller.identity ??
        (providerId == null || sourceAccountId.trim().isEmpty
            ? null
            : AcademicIdentityKey(
                appUserId: appUserId,
                providerId: providerId,
                studentId: sourceAccountId,
              ));
    final identityNamespace = identity?.storageId;
    final sourceSystem =
        identity?.providerId.value ?? providerId?.value ?? 'edu';
    final vault = AesGcmAccountScopedSnapshotStore(
      appUserId: appUserId,
      identityNamespace: identityNamespace,
    );
    return AcademicPersistencePolicy(
      appUserId: appUserId,
      identity: identity,
      preferences: prefs,
      academicStore: AcademicCacheStore(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
        sourceSystem: sourceSystem,
        identityNamespace: identityNamespace,
        snapshotStore: vault,
        persistenceGate: RegistryAcademicPersistenceGate(appUserId),
      ),
      scheduleStore: ScheduleCacheStore(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
        sourceSystem: sourceSystem,
        identityNamespace: identityNamespace,
        snapshotStore: vault,
        persistenceGate: RegistryAcademicPersistenceGate(appUserId),
      ),
      auxiliaryCleanup: AcademicPersistencePolicy.clearAuxiliaryData,
    );
  }

  Future<AcademicCredential?> _readCredentialForCurrentIdentity(
    String appUserId,
  ) {
    final identity = controller.identity;
    if (identity != null &&
        credentialStore is IdentityScopedAcademicCredentialStore) {
      return (credentialStore as IdentityScopedAcademicCredentialStore)
          .readForIdentity(identity);
    }
    return credentialStore.read(appUserId);
  }

  Future<void> _writeCredentialForIdentity(
    String appUserId,
    AcademicIdentityKey? identity,
    AcademicCredential credential,
  ) {
    if (identity != null &&
        credentialStore is IdentityScopedAcademicCredentialStore) {
      return (credentialStore as IdentityScopedAcademicCredentialStore)
          .writeForIdentity(identity, credential);
    }
    return credentialStore.write(appUserId, credential);
  }

  Future<void> _deleteCredentialForIdentity(
      String appUserId, AcademicIdentityKey? identity) {
    if (identity != null &&
        credentialStore is IdentityScopedAcademicCredentialStore) {
      return (credentialStore as IdentityScopedAcademicCredentialStore)
          .deleteForIdentity(identity);
    }
    return credentialStore.delete(appUserId);
  }
}
