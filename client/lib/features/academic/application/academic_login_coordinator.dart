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
import '../data/academic_identity_client.dart';
import '../data/graduate/graduate_protocol_client.dart';
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
    required this.credential,
    required this.saveCredentials,
    required this.saveAcademicData,
  });

  final String appUserId;
  final int generation;
  final AcademicCredential credential;
  final bool saveCredentials;
  final bool saveAcademicData;
}

final class _PendingIdentityVerification {
  const _PendingIdentityVerification({
    required this.appUserId,
    required this.generation,
    required this.credential,
    required this.saveCredentials,
    required this.saveAcademicData,
    required this.challenge,
  });

  final String appUserId;
  final int generation;
  final AcademicCredential credential;
  final bool saveCredentials;
  final bool saveAcademicData;
  final AcademicIdentityChallenge challenge;
}

/// 连接凭据存储、本机资料策略和运行时学校 Session 的协调层。
///
/// SessionController 不接触 Secure Store；验证码阶段的密码只保留在这里的
/// pending 对象中，直到学校最终返回登录成功。
final class AcademicLoginCoordinator {
  AcademicLoginCoordinator({
    required this.controller,
    AcademicCredentialStore? credentialStore,
    AcademicIdentityClient? identityClient,
    Future<AppPreferencesStore> Function()? preferencesLoader,
    this.persistencePolicy,
  })  : credentialStore = credentialStore ?? PlatformAcademicCredentialStore(),
        _identityClient =
            identityClient ?? controller.providerRouter?.identityClient,
        _preferencesLoader =
            preferencesLoader ?? AppPreferencesStore.getInstance;

  final AcademicSessionController controller;
  final AcademicCredentialStore credentialStore;
  final AcademicIdentityClient? _identityClient;
  final Future<AppPreferencesStore> Function() _preferencesLoader;
  final AcademicPersistencePolicy? persistencePolicy;
  Future<AcademicLoginOutcome>? _ensureInFlight;
  _PendingAcademicLogin? _pending;
  _PendingIdentityVerification? _pendingIdentity;

  AcademicIdentityChallenge? get pendingIdentityChallenge =>
      _pendingIdentity?.challenge;

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
    final preferences = await _loadPreferences();
    if (!preferences.saveCredentials) return null;
    return readSavedCredential();
  }

  Future<AcademicStoragePreferences> loadPreferences() => _loadPreferences();

  Future<bool> hasSavedCredential() async =>
      (await readEnabledCredential()) != null;

  Future<AcademicLoginOutcome> login({
    required String studentId,
    String password = '',
    required bool saveCredentials,
    required bool saveAcademicData,
    bool useSavedCredential = false,
    AcademicProviderId? providerId,
  }) {
    final appUserId = controller.appUserId;
    if (appUserId == null || appUserId.isEmpty) {
      return Future.value(const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '请先登录 APP',
      ));
    }
    if (controller.sourceKind == AcademicSourceKind.legacy &&
        providerId == AcademicProviderId.syluGraduate) {
      return _beginGraduateIdentityVerification(
        appUserId: appUserId,
        studentId: studentId,
        password: password,
        saveCredentials: saveCredentials,
        saveAcademicData: saveAcademicData,
        useSavedCredential: useSavedCredential,
      );
    }
    if (controller.sourceKind == AcademicSourceKind.legacy &&
        providerId == AcademicProviderId.syluUndergraduate &&
        _identityClient != null) {
      return _beginUndergraduateLogin(
        appUserId: appUserId,
        studentId: studentId,
        password: password,
        saveCredentials: saveCredentials,
        saveAcademicData: saveAcademicData,
        useSavedCredential: useSavedCredential,
      );
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

  Future<AcademicLoginOutcome> continueLoginWithCaptcha({
    required String code,
  }) async {
    final pendingIdentity = _pendingIdentity;
    if (pendingIdentity != null) {
      return _verifyGraduateIdentity(
        pendingIdentity: pendingIdentity,
        captcha: code,
      );
    }
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
      credential: pending.credential,
      saveCredentials: pending.saveCredentials,
      saveAcademicData: pending.saveAcademicData,
    );
  }

  Future<AcademicLoginOutcome> _beginUndergraduateLogin({
    required String appUserId,
    required String studentId,
    required String password,
    required bool saveCredentials,
    required bool saveAcademicData,
    required bool useSavedCredential,
  }) async {
    final client = _identityClient;
    if (client == null) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '教务身份验证服务未接入，请稍后重试',
      );
    }
    var actualPassword = password;
    final actualStudentId = studentId.trim();
    if (useSavedCredential && actualPassword.isEmpty) {
      final saved = await _readCredentialForCurrentIdentity(appUserId);
      if (saved == null || saved.studentId.trim() != actualStudentId) {
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
    AcademicIdentityChallenge? challenge;
    try {
      challenge = await client.requestChallenge(
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: actualStudentId,
      );
    } on AcademicIdentityApiException catch (error) {
      // 旧部署尚未提供身份路由时仍可使用 /edu/bind；新路由的业务错误
      // 必须显示给用户，不能悄悄变成密码错误。
      if (error.statusCode != 404 && error.code != 'ROUTE_UNSUPPORTED') {
        return _identityFailureOutcome(error);
      }
      // 只有 challenge 路由本身明确不存在时才走旧兼容接口。
      challenge = null;
    }
    if (challenge != null) {
      if (!challenge.isUndergraduatePreverify) {
        return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.failure,
          message: '本科教务身份验证模式无效，请稍后重试',
        );
      }
      if (!controller.isCurrentContext(
        generation: generation,
        appUserId: appUserId,
      )) {
        return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.contextChanged,
          message: '教务账号上下文已切换，请重新登录',
        );
      }
      AcademicIdentityBinding binding;
      try {
        binding = await client.verifyUndergraduatePreverify(
          challenge: challenge,
          password: actualPassword,
        );
      } on AcademicIdentityApiException catch (error) {
        // challenge 已明确选择新契约；verify 失败（包括 404）不得再
        // 把同一份凭据发送到旧 /edu/bind。
        return _identityFailureOutcome(error);
      }
      if (!controller.isCurrentContext(
        generation: generation,
        appUserId: appUserId,
      )) {
        return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.contextChanged,
          message: '教务账号上下文已切换，请重新登录',
        );
      }
      await controller.selectProviderIdentity(binding.toIdentity(appUserId));
      // 身份核验不会把学校 Cookie 转移到手机；成功后仍由本机
      // Undergraduate Provider 独立登录并取得自己的会话。
      final result = await controller.login(
        studentId: actualStudentId,
        password: actualPassword,
      );
      return _handleLoginResult(
        result,
        appUserId: appUserId,
        generation: generation,
        credential: AcademicCredential(
          studentId: actualStudentId,
          password: actualPassword,
        ),
        saveCredentials: saveCredentials,
        saveAcademicData: saveAcademicData,
      );
    }
    return _login(
      appUserId: appUserId,
      studentId: actualStudentId,
      password: actualPassword,
      saveCredentials: saveCredentials,
      saveAcademicData: saveAcademicData,
      useSavedCredential: useSavedCredential,
    );
  }

  Future<AcademicLoginOutcome> _beginGraduateIdentityVerification({
    required String appUserId,
    required String studentId,
    required String password,
    required bool saveCredentials,
    required bool saveAcademicData,
    required bool useSavedCredential,
  }) async {
    final client = _identityClient;
    if (client == null) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '教务身份验证服务未接入，请稍后重试',
      );
    }
    var actualPassword = password;
    final actualStudentId = studentId.trim();
    if (useSavedCredential && actualPassword.isEmpty) {
      final saved = await _readCredentialForCurrentIdentity(appUserId);
      if (saved == null || saved.studentId.trim() != actualStudentId) {
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
    try {
      final challenge = await client.requestChallenge(
        providerId: AcademicProviderId.syluGraduate,
        studentId: actualStudentId,
      );
      if (challenge == null) {
        return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.failure,
          message: '研究生教务未返回可验证挑战',
        );
      }
      final captchaBytes = challenge.captchaBytes;
      final schoolPublicKey = challenge.schoolPublicKey;
      if (captchaBytes == null ||
          captchaBytes.isEmpty ||
          schoolPublicKey == null ||
          schoolPublicKey.trim().isEmpty) {
        return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.failure,
          message: '研究生教务挑战响应无效，请重新获取挑战',
        );
      }
      if (!controller.isCurrentContext(
        generation: generation,
        appUserId: appUserId,
      )) {
        return const AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.contextChanged,
          message: '教务账号上下文已切换，请重新登录',
        );
      }
      _pending = null;
      _pendingIdentity = _PendingIdentityVerification(
        appUserId: appUserId,
        generation: generation,
        credential: AcademicCredential(
          studentId: actualStudentId,
          password: actualPassword,
        ),
        saveCredentials: saveCredentials,
        saveAcademicData: saveAcademicData,
        challenge: challenge,
      );
      controller.presentCaptchaChallenge(captchaBytes);
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.captchaRequired,
        message: '请完成研究生教务身份验证',
      );
    } on AcademicIdentityApiException catch (error) {
      return _identityFailureOutcome(error);
    }
  }

  Future<AcademicLoginOutcome> _verifyGraduateIdentity({
    required _PendingIdentityVerification pendingIdentity,
    required String captcha,
  }) async {
    if (!controller.isCurrentContext(
      generation: pendingIdentity.generation,
      appUserId: pendingIdentity.appUserId,
    )) {
      _pendingIdentity = null;
      controller.dismissCaptchaChallenge();
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.contextChanged,
        message: '教务账号上下文已切换，请重新登录',
      );
    }
    final client = _identityClient;
    if (client == null) {
      _pendingIdentity = null;
      controller.dismissCaptchaChallenge();
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '教务身份验证服务未接入，请稍后重试',
      );
    }
    final consumed = pendingIdentity;
    // 服务端第一次 Verify 尝试就消费 challenge；客户端同步丢弃本地 token。
    _pendingIdentity = null;
    try {
      final encryptedPassword = GraduateAuthCodec.encryptPassword(
        consumed.credential.password,
        consumed.challenge.schoolPublicKey!,
      );
      final binding = await client.verify(
        challenge: consumed.challenge,
        captcha: captcha,
        encryptedPassword: encryptedPassword,
      );
      await controller.selectProviderIdentity(
        binding.toIdentity(consumed.appUserId),
      );
      controller.dismissCaptchaChallenge();
      // 服务端验证只确认身份，不把学校 Cookie 转移到手机；随后由本机
      // Graduate Provider 重新登录并取得独立会话，通常会产生第二张验证码。
      final result = await controller.login(
        studentId: consumed.credential.studentId,
        password: consumed.credential.password,
      );
      return _handleLoginResult(
        result,
        appUserId: consumed.appUserId,
        generation: consumed.generation,
        credential: consumed.credential,
        saveCredentials: consumed.saveCredentials,
        saveAcademicData: consumed.saveAcademicData,
      );
    } on AcademicIdentityApiException catch (error) {
      controller.dismissCaptchaChallenge();
      return _identityFailureOutcome(error);
    } on GraduatePortalException {
      controller.dismissCaptchaChallenge();
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '研究生教务密码加密失败，请重新获取挑战',
      );
    }
  }

  AcademicLoginOutcome _identityFailureOutcome(
    AcademicIdentityApiException error,
  ) {
    final code = error.code.toUpperCase();
    final kind = switch (code) {
      'ACADEMIC_CHALLENGE_REJECTED' ||
      'ACADEMIC_CHALLENGE_REPLAYED' ||
      'ACADEMIC_CHALLENGE_EXPIRED' ||
      'CHALLENGE_REJECTED' =>
        AcademicLoginOutcomeKind.challengeRejected,
      'ACADEMIC_CREDENTIAL_REJECTED' ||
      'CREDENTIAL_REJECTED' =>
        AcademicLoginOutcomeKind.invalidCredentials,
      'ACADEMIC_ACCOUNT_REJECTED' ||
      'ACCOUNT_REJECTED' =>
        AcademicLoginOutcomeKind.accountRejected,
      'ACADEMIC_ACCOUNT_RESTRICTED' ||
      'ACCOUNT_RESTRICTED' =>
        AcademicLoginOutcomeKind.accountRestricted,
      'ACADEMIC_IDENTITY_MISMATCH' ||
      'IDENTITY_MISMATCH' =>
        AcademicLoginOutcomeKind.identityMismatch,
      'ACADEMIC_IDENTITY_UNVERIFIED' ||
      'IDENTITY_UNVERIFIED' =>
        AcademicLoginOutcomeKind.identityUnverified,
      'ACADEMIC_AUTH_REJECTED_AMBIGUOUS' ||
      'AUTH_REJECTED_AMBIGUOUS' =>
        AcademicLoginOutcomeKind.authRejectedAmbiguous,
      'UNAVAILABLE' ||
      'ACADEMIC_PROVIDER_UNAVAILABLE' =>
        AcademicLoginOutcomeKind.networkFailure,
      _ => AcademicLoginOutcomeKind.failure,
    };
    return AcademicLoginOutcome(kind: kind, message: error.message);
  }

  Future<AcademicLoginOutcome> ensureAuthenticated({
    bool allowSavedCredential = true,
  }) {
    if (controller.isAuthenticated) {
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
    if (!allowSavedCredential) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.credentialsRequired,
        message: '请输入教务账号和密码',
      );
    }
    final saved = await readEnabledCredential();
    if (saved == null) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.credentialsRequired,
        message: '请先输入教务账号和密码',
      );
    }
    final prefs = await _loadPreferences();
    return _login(
      appUserId: controller.appUserId!,
      studentId: saved.studentId,
      password: saved.password,
      saveCredentials: true,
      saveAcademicData: prefs.saveAcademicData,
      useSavedCredential: false,
    );
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
    final result = await controller.login(
      studentId: actualStudentId,
      password: actualPassword,
    );
    return _handleLoginResult(
      result,
      appUserId: appUserId,
      generation: generation,
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
        await _deleteCredentialQuietly(appUserId);
        return AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.invalidCredentials,
          message: message,
        );
      case NetworkUnavailable(:final message):
        _pending = null;
        return AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.networkFailure,
          message: message,
        );
      case LoginSuccess():
        _pending = null;
        return _finalizeSuccess(
          appUserId: appUserId,
          credential: credential,
          saveCredentials: saveCredentials,
          saveAcademicData: saveAcademicData,
        );
      case CaptchaExpired(:final message):
      case LoginPageChanged(:final message):
        _pending = null;
        return AcademicLoginOutcome(
          kind: AcademicLoginOutcomeKind.failure,
          message: message,
        );
    }
  }

  Future<AcademicLoginOutcome> _finalizeSuccess({
    required String appUserId,
    required AcademicCredential credential,
    required bool saveCredentials,
    required bool saveAcademicData,
  }) async {
    var saveWarning = false;
    // 服务端模式不读取或修改本机密码，资料缓存仍按独立策略处理。
    if (controller.sourceKind == AcademicSourceKind.local) {
      AcademicStoragePreferences? preferences;
      try {
        preferences =
            persistencePolicy?.preferences ?? await _loadPreferences();
        if (saveCredentials) {
          await _writeCredentialForCurrentIdentity(appUserId, credential);
          await preferences.setSaveCredentials(true);
        } else {
          await _deleteCredentialForCurrentIdentity(appUserId);
          await preferences.setSaveCredentials(false);
        }
      } catch (_) {
        saveWarning = true;
        // Secure Store 写入成功但偏好写入失败时回滚凭据，避免出现用户以为
        // 未保存、设备却仍残留学校密码的半成功状态。
        try {
          await _deleteCredentialForCurrentIdentity(appUserId);
        } catch (_) {}
        // 任一凭据持久化步骤失败时关闭有效开关，避免残留凭据被自动使用。
        try {
          preferences ??=
              persistencePolicy?.preferences ?? await _loadPreferences();
          await preferences.setSaveCredentials(false);
        } catch (_) {}
      }
    }

    try {
      final policy = persistencePolicy ??
          await _createPersistencePolicy(
            appUserId: appUserId,
            sourceAccountId: controller.studentId ?? credential.studentId,
          );
      if (saveAcademicData) {
        await policy.enable();
      } else {
        await policy.disableAndClear();
      }
    } catch (_) {
      // 登录成功不能被资料偏好或清理异常回滚；策略会保留 cleanup_pending。
      saveWarning = true;
    }

    return AcademicLoginOutcome(
      kind: AcademicLoginOutcomeKind.success,
      message: saveWarning ? '已登录，但本机保存设置未完全生效' : null,
      saveCredentialWarning: saveWarning,
    );
  }

  Future<AcademicStoragePreferences> _loadPreferences() async {
    final appUserId = controller.appUserId ?? '';
    try {
      return AcademicStoragePreferences(
        appUserId: appUserId,
        store: await _preferencesLoader(),
      );
    } catch (_) {
      // 偏好服务暂时不可用时仍允许手动登录；保存策略会在真正写入时给出警告。
      return AcademicStoragePreferences(
        appUserId: appUserId,
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

  Future<void> _deleteCredentialQuietly(String appUserId) async {
    try {
      await _deleteCredentialForCurrentIdentity(appUserId);
    } catch (_) {}
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

  Future<void> _writeCredentialForCurrentIdentity(
    String appUserId,
    AcademicCredential credential,
  ) {
    final identity = controller.identity;
    if (identity != null &&
        credentialStore is IdentityScopedAcademicCredentialStore) {
      return (credentialStore as IdentityScopedAcademicCredentialStore)
          .writeForIdentity(identity, credential);
    }
    return credentialStore.write(appUserId, credential);
  }

  Future<void> _deleteCredentialForCurrentIdentity(String appUserId) {
    final identity = controller.identity;
    if (identity != null &&
        credentialStore is IdentityScopedAcademicCredentialStore) {
      return (credentialStore as IdentityScopedAcademicCredentialStore)
          .deleteForIdentity(identity);
    }
    return credentialStore.delete(appUserId);
  }
}
