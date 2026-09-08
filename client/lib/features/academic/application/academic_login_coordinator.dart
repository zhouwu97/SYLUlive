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
import '../data/graduate/tflite_academic_captcha_recognizer.dart';
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
    this.captchaSubmissionPolicy = const AcademicCaptchaSubmissionPolicy(),
    this.silentCaptcha = true,
    AcademicCaptchaRecognizer Function()? identityCaptchaRecognizerFactory,
  })  : _identityCaptchaRecognizerFactory = identityCaptchaRecognizerFactory ??
            LazyTfliteAcademicCaptchaRecognizer.new,
        credentialStore = credentialStore ?? PlatformAcademicCredentialStore(),
        _identityClient =
            identityClient ?? controller.providerRouter?.identityClient,
        _preferencesLoader =
            preferencesLoader ?? AppPreferencesStore.getInstance;

  final AcademicSessionController controller;
  final AcademicCredentialStore credentialStore;
  final AcademicIdentityClient? _identityClient;
  final Future<AppPreferencesStore> Function() _preferencesLoader;
  final AcademicPersistencePolicy? persistencePolicy;
  final AcademicCaptchaSubmissionPolicy captchaSubmissionPolicy;
  final bool silentCaptcha;
  final AcademicCaptchaRecognizer Function() _identityCaptchaRecognizerFactory;
  Future<AcademicLoginOutcome>? _ensureInFlight;
  _PendingAcademicLogin? _pending;
  _PendingIdentityVerification? _pendingIdentity;
  AcademicIdentityKey? _deviceSetupIdentity;

  AcademicIdentityChallenge? get pendingIdentityChallenge =>
      _pendingIdentity?.challenge;

  Future<void>? _cleanupInFlight;

  Future<void> resumePendingCleanup() {
    final running = _cleanupInFlight;
    if (running != null) return running;
    final user = controller.appUserId;
    final operation = () async {
      if (user == null) return;
      final preferences = await _preferencesLoader();
      for (final identity
          in AcademicConnectionStore.pendingIdentities(preferences, user)) {
        if (controller.appUserId != user) return;
        try {
          await AcademicIdentityLifecycleCoordinator(
                  controller: controller, preferences: preferences)
              .retryPending(identity);
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
    _pendingIdentity = null;
    controller.dismissCaptchaChallenge();
  }

  /// 取消只结束本机认证；服务端已经验证的身份保留，之后可继续设置。
  Future<AcademicLoginOutcome> cancelLogin() async {
    _pending = null;
    _pendingIdentity = null;
    _deviceSetupIdentity = null;
    controller.dismissCaptchaChallenge();
    try {
      await controller.resetSession();
      return const AcademicLoginOutcome(kind: AcademicLoginOutcomeKind.success);
    } catch (_) {
      return const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '身份已保留，本机会话清理未完成，请重试',
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
              ? '身份已验证，本机设置未完成，请重试连接'
              : '教务身份操作未完成，请重试');
    }
  }

  /// 每个认证阶段最多提交两次；刷新后的第三张图只留给人工。
  Future<AcademicLoginOutcome> _completeCaptchaSilently(
      AcademicLoginOutcome outcome) async {
    if (!silentCaptcha) return outcome;
    var attempts = 0;
    var identityStage = _pendingIdentity != null;
    while (outcome.needsCaptcha && attempts < 2) {
      final verification = _pendingIdentity;
      final local = _pending;
      if (verification == null &&
          controller.providerId != AcademicProviderId.syluGraduate) {
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
      attempts++;
      outcome = await continueLoginWithCaptcha(code: code);
      // 身份验证成功后还有本机学校会话，两阶段各自保留一次重试机会。
      if (identityStage &&
          verification != null &&
          _pendingIdentity == null &&
          _pending != null &&
          outcome.needsCaptcha) {
        identityStage = false;
        attempts = 0;
        continue;
      }
      final rejected = outcome.kind ==
              AcademicLoginOutcomeKind.challengeRejected ||
          controller.failure?.kind == AcademicFailureKind.challengeRejected ||
          controller.failure?.kind == AcademicFailureKind.captchaExpired;
      if (!rejected) break;
      final user = verification?.appUserId ?? local?.appUserId;
      final generation = verification?.generation ?? local?.generation;
      if (user == null ||
          generation == null ||
          !controller.isCurrentContext(
              generation: generation, appUserId: user)) {
        return const AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.contextChanged);
      }
      if (verification != null) {
        outcome = await _beginGraduateIdentityVerification(
            currentIdentity:
                verification.challenge.isChange ? controller.identity : null,
            appUserId: user,
            studentId: verification.credential.studentId,
            password: verification.credential.password,
            saveCredentials: verification.saveCredentials,
            saveAcademicData: verification.saveAcademicData,
            useSavedCredential: false);
      } else if (local != null) {
        outcome = await _login(
            appUserId: user,
            studentId: local.credential.studentId,
            password: local.credential.password,
            saveCredentials: local.saveCredentials,
            saveAcademicData: local.saveAcademicData,
            useSavedCredential: false);
      }
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
  }) {
    final appUserId = controller.appUserId;
    if (appUserId == null || appUserId.isEmpty) {
      return Future.value(const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '请先登录 APP',
      ));
    }
    if (_deviceSetupIdentity != null &&
        _deviceSetupIdentity == controller.identity &&
        _deviceSetupIdentity!.studentId == studentId.trim() &&
        (providerId == null ||
            _deviceSetupIdentity!.providerId == providerId)) {
      return _login(
          appUserId: appUserId,
          studentId: studentId,
          password: password,
          saveCredentials: saveCredentials,
          saveAcademicData: saveAcademicData,
          useSavedCredential: useSavedCredential);
    }
    if ((!controller.hasBoundIdentity || addIdentity || changeIdentity) &&
        providerId == AcademicProviderId.syluGraduate) {
      return _beginGraduateIdentityVerification(
        currentIdentity: changeIdentity ? controller.identity : null,
        appUserId: appUserId,
        studentId: studentId,
        password: password,
        saveCredentials: saveCredentials,
        saveAcademicData: saveAcademicData,
        useSavedCredential: useSavedCredential,
      );
    }
    if ((!controller.hasBoundIdentity || addIdentity || changeIdentity) &&
        providerId == AcademicProviderId.syluUndergraduate &&
        _identityClient != null) {
      return _beginUndergraduateLogin(
        currentIdentity: changeIdentity ? controller.identity : null,
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

  Future<void> refreshCaptcha() async {
    final verification = _pendingIdentity;
    if (verification != null) {
      if (!controller.isCurrentContext(
          generation: verification.generation,
          appUserId: verification.appUserId)) {
        cancelIdentityVerification();
        return;
      }
      _pendingIdentity = null;
      final outcome = await _beginGraduateIdentityVerification(
          currentIdentity:
              verification.challenge.isChange ? controller.identity : null,
          appUserId: verification.appUserId,
          studentId: verification.credential.studentId,
          password: verification.credential.password,
          saveCredentials: verification.saveCredentials,
          saveAcademicData: verification.saveAcademicData,
          useSavedCredential: false);
      if (!outcome.needsCaptcha) controller.dismissCaptchaChallenge();
      return;
    }
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
              ? '身份已验证，本机设置未完成，请重试连接'
              : '验证码操作未完成，请重试');
    }
  }

  Future<AcademicLoginOutcome> _continueLoginWithCaptcha({
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
    AcademicIdentityKey? currentIdentity,
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
        currentIdentity: currentIdentity,
        providerId: AcademicProviderId.syluUndergraduate,
        studentId: actualStudentId,
      );
    } on AcademicIdentityApiException catch (error) {
      return _identityFailureOutcome(error);
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
      final verifiedIdentity = binding.toIdentity(appUserId);
      final mountedGeneration = await _mountVerifiedBinding(
        verifiedIdentity,
        changing: challenge.isChange,
      );
      if (!controller.isCurrentContext(
          generation: mountedGeneration, appUserId: appUserId)) {
        return const AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.contextChanged);
      }
      _deviceSetupIdentity = verifiedIdentity;
      // 身份核验不会把学校 Cookie 转移到手机；成功后仍由本机
      // Undergraduate Provider 独立登录并取得自己的会话。
      final result = await controller.login(
        studentId: actualStudentId,
        password: actualPassword,
      );
      return _handleLoginResult(
        result,
        appUserId: appUserId,
        generation: mountedGeneration,
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
    AcademicIdentityKey? currentIdentity,
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
        currentIdentity: currentIdentity,
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
      final pending = _pendingIdentity;
      AcademicCaptchaRecognition? suggestion;
      final recognizer = _identityCaptchaRecognizerFactory();
      try {
        final result = await recognizer.recognize(captchaBytes);
        if (recognizer.isAvailable && result.isManualSuggestion) {
          suggestion = result;
        }
      } catch (_) {
        // 模型不可用时继续人工挑战，不能丢弃已经保留的密码。
      } finally {
        recognizer.close();
      }
      if (!identical(_pendingIdentity, pending) ||
          !controller.isCurrentContext(
              generation: generation, appUserId: appUserId)) {
        return const AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.contextChanged);
      }
      controller.presentCaptchaChallenge(captchaBytes,
          suggestedCode: suggestion?.text,
          suggestionConfidence: suggestion?.confidence);
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
      if (!controller.isCurrentContext(
          generation: consumed.generation, appUserId: consumed.appUserId)) {
        return const AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.contextChanged);
      }
      final verifiedIdentity = binding.toIdentity(consumed.appUserId);
      final mountedGeneration = await _mountVerifiedBinding(
        verifiedIdentity,
        changing: consumed.challenge.isChange,
      );
      if (!controller.isCurrentContext(
          generation: mountedGeneration, appUserId: consumed.appUserId)) {
        return const AcademicLoginOutcome(
            kind: AcademicLoginOutcomeKind.contextChanged);
      }
      _deviceSetupIdentity = verifiedIdentity;
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
        generation: mountedGeneration,
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

  Future<int> _mountVerifiedBinding(AcademicIdentityKey next,
      {required bool changing}) async {
    final old = changing ? controller.identity : null;
    await controller.selectProviderIdentity(next);
    await controller.allowDeviceConnection();
    final generation = controller.contextGeneration;
    if (old == null || old == next) return generation;
    try {
      await AcademicIdentityLifecycleCoordinator(
              controller: controller,
              preferences: await _preferencesLoader(),
              includeLegacyAuxiliary: true)
          .clearLocalIdentity(old);
    } catch (_) {
      // 服务端已成功换绑，旧身份已从运行时卸载；删除失败由 pending 重试，不回滚绑定。
    }
    return generation;
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
            message: controller.failure?.message ?? '请先添加学生身份');
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
    final saved = await readEnabledCredential();
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
        final outcome = await controller.commit(() => _finalizeSuccess(
              generation: generation,
              appUserId: appUserId,
              credential: credential,
              saveCredentials: saveCredentials,
              saveAcademicData: saveAcademicData,
            ));
        if (outcome.isSuccess && _deviceSetupIdentity == controller.identity) {
          _deviceSetupIdentity = null;
        }
        return outcome;
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
    // 服务端模式不读取或修改本机密码，资料缓存仍按独立策略处理。
    if (controller.sourceKind == AcademicSourceKind.local) {
      AcademicStoragePreferences? preferences;
      try {
        preferences =
            persistencePolicy?.preferences ?? await _loadPreferences();
        if (!current()) return changed;
        if (saveCredentials) {
          await _writeCredentialForCurrentIdentity(appUserId, credential);
          await preferences.setSaveCredentials(true);
        } else {
          await _deleteCredentialForCurrentIdentity(appUserId);
          await preferences.setSaveCredentials(false);
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

    return AcademicLoginOutcome(
      kind: AcademicLoginOutcomeKind.success,
      message: saveWarning ? '已登录，但本机保存设置未完全生效' : null,
      saveCredentialWarning: saveWarning,
    );
  }

  Future<AcademicStoragePreferences> _loadPreferences() async {
    final appUserId = controller.appUserId ?? '';
    try {
      final preferences = AcademicStoragePreferences(
        appUserId: appUserId,
        identity: controller.identity,
        store: await _preferencesLoader(),
      );
      await preferences.migrateLegacyPreferences();
      return preferences;
    } catch (_) {
      // 偏好服务暂时不可用时仍允许手动登录；保存策略会在真正写入时给出警告。
      return AcademicStoragePreferences(
        appUserId: appUserId,
        identity: controller.identity,
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
