import 'dart:async';

import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../../../platform/contracts/preferences_store.dart';
import '../storage/academic_credential_store.dart';
import '../storage/academic_persistence_policy.dart';
import '../storage/academic_storage_preferences.dart';
import '../../campus_data/storage/academic_cache_store.dart';
import '../../campus_data/storage/account_scoped_snapshot_store.dart';
import '../../campus_data/storage/schedule_cache_store.dart';
import 'academic_session_controller.dart';

enum AcademicLoginOutcomeKind {
  success,
  captchaRequired,
  credentialsRequired,
  invalidCredentials,
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

/// 连接凭据存储、本机资料策略和运行时学校 Session 的协调层。
///
/// SessionController 不接触 Secure Store；验证码阶段的密码只保留在这里的
/// pending 对象中，直到学校最终返回登录成功。
final class AcademicLoginCoordinator {
  AcademicLoginCoordinator({
    required this.controller,
    AcademicCredentialStore? credentialStore,
    Future<AppPreferencesStore> Function()? preferencesLoader,
    this.persistencePolicy,
  })  : credentialStore = credentialStore ?? PlatformAcademicCredentialStore(),
        _preferencesLoader =
            preferencesLoader ?? AppPreferencesStore.getInstance;

  final AcademicSessionController controller;
  final AcademicCredentialStore credentialStore;
  final Future<AppPreferencesStore> Function() _preferencesLoader;
  final AcademicPersistencePolicy? persistencePolicy;
  Future<AcademicLoginOutcome>? _ensureInFlight;
  _PendingAcademicLogin? _pending;

  Future<AcademicCredential?> readSavedCredential() async {
    final appUserId = controller.appUserId;
    if (appUserId == null) return null;
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
  }) {
    final appUserId = controller.appUserId;
    if (appUserId == null || appUserId.isEmpty) {
      return Future.value(const AcademicLoginOutcome(
        kind: AcademicLoginOutcomeKind.failure,
        message: '请先登录 APP',
      ));
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
      final saved = await credentialStore.read(appUserId);
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
    AcademicStoragePreferences? preferences;
    try {
      preferences = persistencePolicy?.preferences ?? await _loadPreferences();
      if (saveCredentials) {
        await credentialStore.write(appUserId, credential);
        await preferences.setSaveCredentials(true);
      } else {
        await credentialStore.delete(appUserId);
        await preferences.setSaveCredentials(false);
      }
    } catch (_) {
      saveWarning = true;
      // 任一凭据持久化步骤失败时关闭有效开关，避免残留凭据被自动使用。
      try {
        preferences ??=
            persistencePolicy?.preferences ?? await _loadPreferences();
        await preferences.setSaveCredentials(false);
      } catch (_) {}
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
    final vault = AesGcmAccountScopedSnapshotStore(appUserId: appUserId);
    return AcademicPersistencePolicy(
      appUserId: appUserId,
      preferences: prefs,
      academicStore: AcademicCacheStore(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
        snapshotStore: vault,
      ),
      scheduleStore: ScheduleCacheStore(
        appUserId: appUserId,
        sourceAccountId: sourceAccountId,
        snapshotStore: vault,
      ),
      auxiliaryCleanup: AcademicPersistencePolicy.clearAuxiliaryData,
    );
  }

  Future<void> _deleteCredentialQuietly(String appUserId) async {
    try {
      await credentialStore.delete(appUserId);
    } catch (_) {}
  }
}
