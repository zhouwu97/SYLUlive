import 'dart:async';

import '../../../platform/contracts/preferences_store.dart';
import '../storage/academic_connection_store.dart';
import '../data/graduate/graduate_protocol_client.dart';

import 'package:flutter/foundation.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import '../../../services/account_session_cleanup_coordinator.dart';
import '../data/provider_academic_repository.dart';
import '../data/academic_provider_router_repository.dart';
import '../data/academic_identity_client.dart';
import '../storage/academic_session_artifact_vault.dart';
import '../domain/academic_failure.dart';
import '../domain/academic_provider.dart';
import '../domain/academic_repository.dart';

enum AcademicConnectionPreference { connected, disconnected }

enum AcademicState {
  identityUnbound,
  disconnected,
  localCredentialRequired,
  authChallengeRequired,
  credentialUpdateRequired,
  identityMismatch,
  ready,
  unavailable,
}

final class PendingAcademicChallenge {
  const PendingAcademicChallenge({
    required this.challengeId,
    required this.identity,
    required this.generation,
    required this.createdAt,
  });

  final String challengeId;
  final AcademicIdentityKey identity;
  final int generation;
  final DateTime createdAt;
}

enum AcademicSessionStatus {
  idle,
  authenticating,
  awaitingCaptcha,
  authenticated,
  loading,
  error,
}

/// 教务个人资料的独立加载状态。
///
/// 学校认证成功只代表 Cookie 会话有效，不能推导个人资料页面也一定可用。
enum AcademicProfileStatus {
  idle,
  loading,
  loaded,
  error,
}

/// 主应用教务会话控制器。
///
/// 控制器只持有当前运行时状态，不持久化教务密码或 Cookie。所有网络操作
/// 串行执行，账号切换和退出会通过 [AccountSessionCleanupCoordinator] 清理
/// 同一实例中的 pending 登录与 CookieJar。
final class AcademicSessionController extends ChangeNotifier {
  AcademicSessionController({
    AcademicRepository? repository,
    AcademicProvider? provider,
    AcademicIdentityKey? identity,
    AcademicSessionArtifactVault Function(AcademicIdentityKey identity)?
        sessionArtifactVaultFactory,
    AccountSessionCleanupCoordinator? cleanupCoordinator,
  })  : _repository = repository ?? _repositoryFor(provider),
        _provider = provider,
        _identity = identity ?? provider?.identity,
        _sessionArtifactVaultFactory = sessionArtifactVaultFactory,
        _cleanupCoordinator =
            cleanupCoordinator ?? AccountSessionCleanupCoordinator.instance {
    _cleanupCoordinator.register(this, resetSession);
  }

  AcademicSessionController.forProvider({
    required AcademicProvider provider,
    required AcademicIdentityKey identity,
    AcademicSessionArtifactVault Function(AcademicIdentityKey identity)?
        sessionArtifactVaultFactory,
    AccountSessionCleanupCoordinator? cleanupCoordinator,
  }) : this(
          provider: provider,
          identity: identity,
          sessionArtifactVaultFactory: sessionArtifactVaultFactory,
          cleanupCoordinator: cleanupCoordinator,
        );

  static AcademicRepository _repositoryFor(AcademicProvider? provider) {
    if (provider == null) {
      throw ArgumentError('必须提供 repository 或 provider');
    }
    return ProviderAcademicRepository(provider);
  }

  final AcademicRepository _repository;
  final AcademicProvider? _provider;
  AcademicIdentityKey? _identity;
  final AcademicSessionArtifactVault Function(AcademicIdentityKey identity)?
      _sessionArtifactVaultFactory;
  final AccountSessionCleanupCoordinator _cleanupCoordinator;

  Future<void> _operationTail = Future<void>.value();
  String? _appUserId;
  String? _studentId;
  StudentProfile? _profile;
  CaptchaChallenge? _captchaChallenge;
  CourseFetchResult? _lastCourses;
  GradeFetchResult? _lastGrades;
  AcademicFailure? _failure;
  AcademicSessionStatus _status = AcademicSessionStatus.idle;
  AcademicProfileStatus _profileStatus = AcademicProfileStatus.idle;
  int _accountGeneration = 0;
  bool _sessionResetPending = false;
  bool _serverBindingStatusResolved = false;
  bool _disposed = false;
  AcademicConnectionPreference _connectionPreference =
      AcademicConnectionPreference.connected;
  PendingAcademicChallenge? _pendingAcademicChallenge;
  Future<bool>? _reloginFuture;

  String? get appUserId => _appUserId;
  AcademicIdentityKey? get identity =>
      _identity ??
      (_repository is AcademicProviderRouterRepository
          ? (_repository as AcademicProviderRouterRepository).selectedIdentity
          : null);
  AcademicProvider? get provider =>
      _provider ??
      (_repository is AcademicProviderRouterRepository
          ? (_repository as AcademicProviderRouterRepository).selectedProvider
          : null);
  AcademicProviderRouterRepository? get providerRouter =>
      _repository is AcademicProviderRouterRepository
          ? _repository as AcademicProviderRouterRepository
          : null;
  AcademicProviderId? get providerId => identity?.providerId;

  /// 服务端已确认的教务身份独立于本机学校 Session；本机会话过期时仍
  /// 保留该状态，页面才能显示“已绑定，待恢复”而不是要求重复绑定。
  bool get hasBoundIdentity {
    final currentIdentity = identity;
    final appUserId = _appUserId;
    return currentIdentity != null &&
        appUserId != null &&
        currentIdentity.appUserId.trim() == appUserId.trim();
  }

  AcademicConnectionPreference get connectionPreference =>
      _connectionPreference;
  PendingAcademicChallenge? get pendingAcademicChallenge =>
      _pendingAcademicChallenge;
  int get contextGeneration => _accountGeneration;

  AcademicState get academicState {
    final currentIdentity = identity;
    if (currentIdentity == null && _appUserId == null) {
      return AcademicState.identityUnbound;
    }
    if (currentIdentity != null &&
        _appUserId != null &&
        currentIdentity.appUserId.trim() != _appUserId!.trim()) {
      return AcademicState.identityMismatch;
    }
    if (_connectionPreference == AcademicConnectionPreference.disconnected) {
      return AcademicState.disconnected;
    }
    if (_failure != null) {
      return switch (_failure!.kind) {
        AcademicFailureKind.captchaRequired ||
        AcademicFailureKind.captchaExpired =>
          AcademicState.authChallengeRequired,
        AcademicFailureKind.invalidCredentials =>
          AcademicState.credentialUpdateRequired,
        AcademicFailureKind.unauthenticated =>
          AcademicState.localCredentialRequired,
        _ => AcademicState.unavailable,
      };
    }
    if (isAuthenticated) return AcademicState.ready;
    return AcademicState.localCredentialRequired;
  }

  /// 异步登录完成后供协调器确认仍属于原 App 账号。
  bool isCurrentContext({required int generation, String? appUserId}) {
    return !_disposed &&
        generation == _accountGeneration &&
        (appUserId == null || appUserId == _appUserId);
  }

  String? get studentId =>
      _sessionResetPending ? null : (_studentId ?? _repository.studentId);
  AcademicSourceKind get sourceKind => _repository.sourceKind;
  AcademicCapabilities get capabilities => _repository.capabilities;
  StudentProfile? get profile => _profile;
  CaptchaChallenge? get captchaChallenge => _captchaChallenge;
  String? get captchaSuggestion => _captchaChallenge?.suggestedCode;
  double? get captchaSuggestionConfidence => _captchaChallenge?.suggestionConfidence;
  CourseFetchResult? get lastCourses => _lastCourses;
  GradeFetchResult? get lastGrades => _lastGrades;
  AcademicFailure? get failure => _failure;
  AcademicSessionStatus get status => _status;
  AcademicProfileStatus get profileStatus => _profileStatus;
  bool get isProfileLoaded => _profileStatus == AcademicProfileStatus.loaded;
  bool get hasProfileError =>
      _profileStatus == AcademicProfileStatus.error && _profile == null;
  bool get isBusy =>
      _status == AcademicSessionStatus.authenticating ||
      _status == AcademicSessionStatus.loading;
  bool get isAwaitingCaptcha =>
      _status == AcademicSessionStatus.awaitingCaptcha;
  bool get isAuthenticated =>
      _connectionPreference == AcademicConnectionPreference.connected &&
      !_sessionResetPending &&
      _repository.sessionState == SessionState.authenticated;

  /// 服务端来源只有在 `/edu/status` 成功返回后，才允许页面把未认证解释为未绑定。
  ///
  /// 网络故障、服务端异常等情况只是“暂时未知”，不能误导用户重复绑定。
  bool get hasResolvedServerBindingStatus =>
      _repository.sourceKind != AcademicSourceKind.legacy ||
      _serverBindingStatusResolved;
  SessionState get sessionState => _sessionResetPending
      ? SessionState.unauthenticated
      : _repository.sessionState;

  /// 同步 App JWT 的账号上下文。
  ///
  /// App 账号和学校 Session 是两套身份。这里仅在账号发生变化时清理学校
  /// Session，不把 App JWT 传给学校，也不把学校 Cookie 写入 App 存储。
  Future<void> syncAppUser(String? userId) {
    final normalized = userId?.trim();
    final next = normalized == null || normalized.isEmpty ? null : normalized;
    if (_appUserId == next && !_sessionResetPending) {
      return Future<void>.value();
    }

    _connectionPreference = AcademicConnectionPreference.connected;
    _appUserId = next;
    if (_repository is AcademicProviderRouterRepository) {
      (_repository as AcademicProviderRouterRepository).syncAppUser(next);
    }
    final generation = ++_accountGeneration;
    _pendingAcademicChallenge = null;
    _sessionResetPending = true;
    _serverBindingStatusResolved =
        _repository.sourceKind != AcademicSourceKind.legacy || next == null;
    // 服务端授权恢复尚未完成前，页面只能显示恢复中，不能把暂时清空的
    // runtime session 误判为未绑定并引导用户重复输入账号密码。
    _clearViewState(
      _repository.sourceKind == AcademicSourceKind.legacy && next != null
          ? AcademicSessionStatus.loading
          : AcademicSessionStatus.idle,
    );
    _notifyListeners();

    // 账号切换不能复用旧学校 Cookie；清理排入同一队列，避免与进行中的登录
    // 请求并发修改同一个 JiaowuClient。
    return _enqueue<void>(() async {
      if (_disposed || generation != _accountGeneration) return;
      try {
        await _repository.resetSession();
      } catch (error) {
        if (_disposed || generation != _accountGeneration) return;
        // 账号切换期间必须保持 unauthenticated/pending，不能因为清理失败
        // 让后续请求继续复用可能属于上一个账号的 Cookie。
        _failure = AcademicFailure.fromException(error);
        _status = AcademicSessionStatus.error;
        _notifyListeners();
        return;
      }
      if (_disposed || generation != _accountGeneration) return;
      _sessionResetPending = false;
      _notifyListeners();
      if (_repository.sourceKind == AcademicSourceKind.legacy &&
          _appUserId != null) {
        _status = AcademicSessionStatus.loading;
        _notifyListeners();
        try {
          await _repository.restoreSession();
          if (_disposed || generation != _accountGeneration) return;
          if (!await remoteAccessAllowed()) return;
          _studentId = _repository.studentId;
          _serverBindingStatusResolved = true;
          _status = _repository.sessionState == SessionState.authenticated
              ? AcademicSessionStatus.authenticated
              : AcademicSessionStatus.idle;
          if (_repository.sessionState == SessionState.authenticated) {
            try {
              final profile = await _repository.getProfile();
              if (_disposed || generation != _accountGeneration) return;
              _profile = profile;
              _profileStatus = AcademicProfileStatus.loaded;
            } catch (_) {
              // 绑定已恢复时，资料刷新失败不应再次要求用户绑定。
            }
          }
        } catch (error) {
          if (_disposed || generation != _accountGeneration) return;
          // 服务端已经返回过学号时，说明授权仍存在；仅恢复学校会话失败。
          _serverBindingStatusResolved = _repository.studentId != null;
          _failure = AcademicFailure.fromException(error);
          _status = AcademicSessionStatus.error;
        }
        _notifyListeners();
      }
    });
  }

  Future<LoginResult> login({
    required String studentId,
    required String password,
  }) {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (_disposed) {
        return const LoginPageChanged(message: '教务会话控制器已关闭');
      }
      if (generation != _accountGeneration || !await remoteAccessAllowed()) {
        return const LoginPageChanged(message: '本机教务已断开，请先重新连接');
      }
      if (_appUserId == null) {
        return const LoginPageChanged(message: '请先登录 APP');
      }
      if (_sessionResetPending) {
        return LoginPageChanged(
          message: _failure?.message ?? '教务会话清理失败，请重试',
        );
      }

      _status = AcademicSessionStatus.authenticating;
      _failure = null;
      _captchaChallenge = null;
      _pendingAcademicChallenge = null;
      _notifyListeners();

      try {
        final result = await _repository.login(
          studentId: studentId.trim(),
          password: password,
        );
        if (generation != _accountGeneration || _disposed) {
          return const LoginPageChanged(message: '教务账号上下文已切换');
        }
        return _applyLoginResult(result, generation);
      } catch (error) {
        return _handleLoginException(error, generation, stage: 'login');
      }
    });
  }

  Future<LoginResult> continueLoginWithCaptcha({required String code}) {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (_disposed) {
        return const CaptchaExpired(message: '教务会话控制器已关闭');
      }
      if (generation != _accountGeneration || !await remoteAccessAllowed()) {
        return const CaptchaExpired(message: '本机教务已断开');
      }
      if (identity != null &&
          (_pendingAcademicChallenge == null ||
              _pendingAcademicChallenge!.generation != generation ||
              DateTime.now().toUtc().difference(_pendingAcademicChallenge!.createdAt) > const Duration(seconds: 90))) {
        return const CaptchaExpired(message: '验证码登录会话已失效，请重新获取验证码');
      }
      // 验证码挑战是单次消费材料；重试必须由 Provider 生成新的挑战。
      _pendingAcademicChallenge = null;
      _status = AcademicSessionStatus.authenticating;
      _failure = null;
      _notifyListeners();

      try {
        final result = await _repository.continueLoginWithCaptcha(
          code: code.trim(),
        );
        if (generation != _accountGeneration || _disposed) {
          return const CaptchaExpired(message: '教务账号上下文已切换');
        }
        return _applyLoginResult(result, generation);
      } catch (error) {
        return _handleLoginException(error, generation, stage: 'captcha');
      }
    });
  }

  Future<void> refreshCaptcha() {
    final generation = ++_accountGeneration;
    _pendingAcademicChallenge = null;
    return _enqueue(() async {
      if (_disposed || generation != _accountGeneration ||
          !await remoteAccessAllowed()) {
        return;
      }
      _status = AcademicSessionStatus.awaitingCaptcha;
      _failure = null;
      _notifyListeners();
      try {
        final challenge = await switch (_repository) {
          ProviderAcademicRepository repository => repository.refreshCaptchaChallenge(),
          AcademicProviderRouterRepository router => router.refreshCaptchaChallenge(),
          _ => _repository.getCaptchaChallenge(),
        };
        if (generation != _accountGeneration || _disposed) return;
        _captchaChallenge = challenge;
        _pendingAcademicChallenge = _newPendingChallenge();
        _failure = null;
      } catch (error) {
        if (generation != _accountGeneration || _disposed) return;
        final failure = AcademicFailure.fromException(error);
        _failure = failure;
        if (_shouldLeaveCaptchaState(failure)) {
          _captchaChallenge = null;
          _status = AcademicSessionStatus.error;
        }
      }
      _notifyListeners();
    });
  }

  Future<StudentProfile?> loadProfile() {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (!await _prepareRead(generation)) return null;
      _status = AcademicSessionStatus.loading;
      _profile = null;
      _profileStatus = AcademicProfileStatus.loading;
      _failure = null;
      _notifyListeners();
      try {
        final profile = await _repository.getProfile();
        if (generation != _accountGeneration || _disposed) return null;
        _profile = profile;
        _profileStatus = AcademicProfileStatus.loaded;
        _studentId ??= _repository.studentId;
        _status = AcademicSessionStatus.authenticated;
        _failure = null;
        _notifyListeners();
        return profile;
      } catch (error) {
        _handleProfileFailure(error, generation);
        return null;
      }
    });
  }

  Future<CourseFetchResult?> loadCourses({
    required String year,
    required int semester,
    String? providerTermId,
  }) {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (!await _prepareRead(generation)) return null;
      _status = AcademicSessionStatus.loading;
      _failure = null;
      _notifyListeners();
      try {
        final courses = await _repository.getCourses(
          year: year,
          semester: semester,
          providerTermId: providerTermId,
        );
        if (generation != _accountGeneration || _disposed) return null;
        _lastCourses = courses;
        _status = AcademicSessionStatus.authenticated;
        _failure = null;
        _notifyListeners();
        return courses;
      } catch (error) {
        _handleDataFailure(error, generation);
        return null;
      }
    });
  }

  /// 读取当前 Provider 的真实学期列表，供 UI 选择后携带学校 termcode。
  Future<List<AcademicTerm>?> loadTerms() {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (!await _prepareRead(generation)) return null;
      final repository = _repository;
      try {
        final terms = switch (repository) {
          ProviderAcademicRepository provider => provider.fetchTerms(),
          AcademicProviderRouterRepository router => router.fetchTerms(),
          _ => null,
        };
        if (terms == null) return null;
        final resolved = await terms;
        if (!isCurrentContext(generation: generation)) return null;
        _status = AcademicSessionStatus.authenticated;
        _failure = null;
        _notifyListeners();
        return resolved;
      } catch (error) {
        _handleDataFailure(error, generation);
        return null;
      }
    });
  }

  Future<GradeFetchResult?> loadGrades({
    required String year,
    required int semester,
  }) {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (!await _prepareRead(generation)) return null;
      _status = AcademicSessionStatus.loading;
      _failure = null;
      _notifyListeners();
      try {
        final grades = await _repository.getGrades(
          year: year,
          semester: semester,
        );
        if (generation != _accountGeneration || _disposed) return null;
        _lastGrades = grades;
        _status = AcademicSessionStatus.authenticated;
        _failure = null;
        _notifyListeners();
        return grades;
      } catch (error) {
        _handleDataFailure(error, generation);
        return null;
      }
    });
  }

  Future<GradeDetail?> loadGradeDetail({
    required String year,
    required int semester,
    required String classId,
    required String courseName,
    String? courseId,
    String? studentGradeId,
  }) {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (!await _prepareRead(generation)) return null;
      _status = AcademicSessionStatus.loading;
      _failure = null;
      _notifyListeners();
      try {
        final detail = await _repository.getGradeDetail(
          year: year,
          semester: semester,
          classId: classId,
          courseName: courseName,
          courseId: courseId,
          studentGradeId: studentGradeId,
        );
        if (generation != _accountGeneration || _disposed) return null;
        _status = AcademicSessionStatus.authenticated;
        _failure = null;
        _notifyListeners();
        return detail;
      } catch (error) {
        _handleDataFailure(error, generation);
        return null;
      }
    });
  }

  Future<AcademicSituation?> loadAcademicSituation() {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (!await _prepareRead(generation)) return null;
      _status = AcademicSessionStatus.loading;
      _failure = null;
      _notifyListeners();
      try {
        final result = await _repository.getAcademicSituation();
        if (generation != _accountGeneration || _disposed) return null;
        _status = AcademicSessionStatus.authenticated;
        _failure = null;
        _notifyListeners();
        return result;
      } catch (error) {
        _handleDataFailure(error, generation);
        return null;
      }
    });
  }

  Future<CreditRequirement?> loadCreditRequirements() {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (!await _prepareRead(generation)) return null;
      _status = AcademicSessionStatus.loading;
      _failure = null;
      _notifyListeners();
      try {
        final result = await _repository.getCreditRequirements();
        if (generation != _accountGeneration || _disposed) return null;
        _status = AcademicSessionStatus.authenticated;
        _failure = null;
        _notifyListeners();
        return result;
      } catch (error) {
        _handleDataFailure(error, generation);
        return null;
      }
    });
  }

  /// 用户主动断开本机教务时保留凭据/缓存策略，但禁止后台恢复或创建验证码。
  Future<bool> remoteAccessAllowed() async {
    final generation = _accountGeneration;
    final current = identity;
    if (_connectionPreference == AcademicConnectionPreference.disconnected) {
      return false;
    }
    if (current == null) return !_disposed;
    try {
      final store = AcademicConnectionStore(
        current, await AppPreferencesStore.getInstance());
      if (!isCurrentContext(generation: generation) || identity != current) {
        return false;
      }
      if (!store.connected) {
        _connectionPreference = AcademicConnectionPreference.disconnected;
        _notifyListeners();
        return false;
      }
      return true;
    } catch (_) {
      // 无法确认持久连接许可时，不能用默认值启动学校请求。
      return false;
    }
  }

  Future<void> disconnect() async {
    final current = identity;
    // 先阻断新操作，并使已经排队或在途的结果失效。
    _connectionPreference = AcademicConnectionPreference.disconnected;
    _pendingAcademicChallenge = null;
    final invalidatedGeneration = ++_accountGeneration;
    _sessionResetPending = true;
    _clearViewState(AcademicSessionStatus.idle);
    _notifyListeners();
    if (current != null) {
      final store = AcademicConnectionStore(
        current, await AppPreferencesStore.getInstance());
      await store.setConnected(false);
    }
    if (isCurrentContext(generation: invalidatedGeneration)) await resetSession();
    if (current != null) {
      await (_sessionArtifactVaultFactory?.call(current) ??
          AcademicSessionArtifactVault(identity: current)).delete();
    }
    if (identity == current && _sessionResetPending) throw StateError('学校会话清理失败，请重试');
  }

  /// 服务端确认解绑后卸载身份，清理失败也不允许旧会话重新挂载。
  Future<void> acceptIdentityUnbound(AcademicIdentityKey oldIdentity) async {
    if (identity != oldIdentity || _appUserId != oldIdentity.appUserId) return;
    _accountGeneration++;
    _identity = null;
    providerRouter?.invalidateContext();
    _serverBindingStatusResolved = true;
    _pendingAcademicChallenge = null;
    _clearViewState(AcademicSessionStatus.idle);
    await resetSession();
  }

  /// 只有显式重新连接后才恢复学校会话。
  Future<bool> reconnect() async {
    final current = identity;
    final generation = _accountGeneration;
    if (current != null) {
      final store = AcademicConnectionStore(
        current, await AppPreferencesStore.getInstance());
      if (store.cleanupPending) throw StateError('请先完成本机教务资料清理');
      await store.setConnected(true);
    }
    if (!isCurrentContext(generation: generation)) return false;
    _connectionPreference = AcademicConnectionPreference.connected;
    _notifyListeners();
    return ensureAuthenticated(force: true);
  }

  /// 让首次绑定流程把服务端 challenge 图片交给现有验证码 UI。密码和
  /// challenge token 仍由协调器在内存中管理，控制器只保存图片展示模型。
  void presentCaptchaChallenge(Uint8List imageBytes,
      {String? suggestedCode, double? suggestionConfidence}) {
    if (_disposed) return;
    _captchaChallenge = CaptchaChallenge(
      imageBytes: Uint8List.fromList(imageBytes),
      suggestedCode: suggestedCode,
      suggestionConfidence: suggestionConfidence,
    );
    _pendingAcademicChallenge = null;
    _status = AcademicSessionStatus.awaitingCaptcha;
    _failure = null;
    _notifyListeners();
  }

  void dismissCaptchaChallenge() {
    if (_disposed) return;
    _captchaChallenge = null;
    _pendingAcademicChallenge = null;
    if (_status == AcademicSessionStatus.awaitingCaptcha) {
      _status = AcademicSessionStatus.idle;
    }
    _notifyListeners();
  }

  /// 将已由服务端确认的身份切换到对应本机 Provider。切换会销毁旧
  /// Provider，避免本科和研究生 Cookie、验证码状态互相复用。
  Future<void> selectProviderIdentity(AcademicIdentityKey identity) async {
    final router = providerRouter;
    if (router == null) throw StateError('当前教务仓储未启用 Provider 路由');
    final changing = this.identity != null && this.identity != identity;
    if (changing) {
      ++_accountGeneration;
      _pendingAcademicChallenge = null;
      _reloginFuture = null;
      _clearViewState(AcademicSessionStatus.idle);
      _notifyListeners();
    }
    final generation = _accountGeneration;
    await router.selectProvider(identity);
    if (!isCurrentContext(generation: generation)) return;
    _connectionPreference = AcademicConnectionPreference.connected;
    await remoteAccessAllowed();
    if (!isCurrentContext(generation: generation)) return;
    _studentId = identity.studentId;
    _serverBindingStatusResolved = true;
    _clearViewState(AcademicSessionStatus.idle);
    _studentId = identity.studentId;
    _notifyListeners();
  }

  /// 有限 singleflight 会话恢复。每个身份同时只存在一个恢复 Future。
  Future<bool> ensureAuthenticated({bool force = false}) {
    if (_connectionPreference == AcademicConnectionPreference.disconnected ||
        _appUserId == null ||
        _sessionResetPending) {
      return Future<bool>.value(false);
    }
    if (!force && isAuthenticated) return Future<bool>.value(true);
    final running = _reloginFuture;
    if (running != null) return running;
    final generation = _accountGeneration;
    final future = _restoreForGeneration(generation);
    _reloginFuture = future;
    return future.whenComplete(() {
      if (identical(_reloginFuture, future)) _reloginFuture = null;
    });
  }

  Future<bool> _restoreForGeneration(int generation) async {
    // 新身份路由需要先读取服务端确认的身份，才能创建正确的本机
    // Provider 和身份隔离保险箱；不能用初始 legacy 状态提前返回。
    try {
      final router = providerRouter;
      if (router != null && identity == null && _appUserId != null) {
        try {
          await router.ensureIdentitySelection();
        } on AcademicIdentityApiException catch (error) {
          if (error.statusCode != 404 &&
              error.code != 'ROUTE_UNSUPPORTED' &&
              error.code != 'AUTHENTICATION_REQUIRED') {
            rethrow;
          }
        }
      }
      if (!isCurrentContext(generation: generation)) return false;
      if (_repository.sessionState != SessionState.expired &&
          !isAuthenticated &&
          provider == null) {
        return false;
      }
      if (!isCurrentContext(generation: generation)) return false;
      if (!await remoteAccessAllowed()) return false;
      _status = AcademicSessionStatus.loading;
      _notifyListeners();
      final activeProvider = provider;
      final currentIdentity = identity;
      final vaultFactory = _sessionArtifactVaultFactory;
      var restoredFromArtifact = false;
      if (activeProvider != null &&
          currentIdentity != null &&
          vaultFactory != null) {
        if (!isCurrentContext(generation: generation)) return false;
        final artifact = await vaultFactory(currentIdentity).read();
        if (!isCurrentContext(generation: generation)) return false;
        if (artifact != null) {
          try {
            if (!isCurrentContext(generation: generation)) return false;
            await activeProvider.restoreSession(artifact);
            if (!isCurrentContext(generation: generation)) return false;
            if (_repository is ProviderAcademicRepository) {
              // Provider 的 restoreSession 已完成材料校验和探活；这里只同步
              // 兼容仓储状态，避免冷启动重复请求学校资料接口。
              (_repository as ProviderAcademicRepository)
                  .markSessionAuthenticated();
            } else {
              await _repository.restoreSession();
              if (!isCurrentContext(generation: generation)) return false;
            }
            restoredFromArtifact = true;
          } catch (error) {
            final expired = error is AcademicAuthFailure && error.type == AcademicAuthFailureType.sessionExpired ||
                error is SessionExpiredException ||
                error is GraduatePortalException && error.code == 'SESSION_EXPIRED';
            if (!expired) rethrow;
            if (!isCurrentContext(generation: generation)) return false;
            await vaultFactory(currentIdentity).delete();
            await _repository.resetSession();
          }
        }
      }
      if (!isCurrentContext(generation: generation)) return false;
      if (!restoredFromArtifact) {
        await _repository.restoreSession();
        if (!isCurrentContext(generation: generation)) return false;
      }
      if (!isCurrentContext(generation: generation)) return false;
      _studentId = _repository.studentId;
      final authenticated = isAuthenticated;
      if (authenticated) await _persistSessionArtifact(generation);
      if (!isCurrentContext(generation: generation)) return false;
      _status = authenticated
          ? AcademicSessionStatus.authenticated
          : AcademicSessionStatus.idle;
      _failure = null;
      _notifyListeners();
      return authenticated;
    } catch (error) {
      if (!isCurrentContext(generation: generation)) return false;
      _failure = AcademicFailure.fromException(error);
      _status = AcademicSessionStatus.error;
      _notifyListeners();
      return false;
    }
  }

  /// 清理学校会话，但保留当前 App 用户上下文。
  Future<void> resetSession() {
    final restoring = _reloginFuture;
    final generation = ++_accountGeneration;
    _sessionResetPending = true;
    _pendingAcademicChallenge = null;
    _reloginFuture = null;
    _clearViewState(AcademicSessionStatus.idle);
    _notifyListeners();
    return _enqueue(() async {
      if (restoring != null) {
        try { await restoring; } catch (_) { /* 恢复失败仍必须清理运行时。 */ }
      }
      if (_disposed || generation != _accountGeneration) return;
      try {
        await _repository.resetSession();
      } catch (error) {
        if (_disposed || generation != _accountGeneration) return;
        _failure = AcademicFailure.fromException(error);
        _status = AcademicSessionStatus.error;
        _notifyListeners();
        return;
      }
      if (_disposed || generation != _accountGeneration) return;
      _sessionResetPending = false;
      _notifyListeners();
    });
  }

  /// 从服务端恢复当前 App 账号已有的教务授权。
  Future<void> restoreSession({bool force = false}) {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (_disposed || _appUserId == null || generation != _accountGeneration) {
        return;
      }
      if (!await remoteAccessAllowed()) return;
      if (_sessionResetPending) throw StateError('教务账号上下文尚未清理完成');
      // 与启动恢复共用队列，等待中的页面不重复发起同一次恢复请求。
      if (!force && isAuthenticated) return;
      _status = AcademicSessionStatus.loading;
      _failure = null;
      _notifyListeners();
      try {
        await _repository.restoreSession();
        if (_disposed || generation != _accountGeneration) return;
        _studentId = _repository.studentId;
        _serverBindingStatusResolved = true;
        _status = _repository.sessionState == SessionState.authenticated
            ? AcademicSessionStatus.authenticated
            : AcademicSessionStatus.idle;
      } catch (error) {
        if (_disposed || generation != _accountGeneration) return;
        // 会话恢复失败不等于撤销绑定；保留服务端确认过的学号供页面重试。
        _studentId = _repository.studentId;
        _serverBindingStatusResolved = _repository.studentId != null;
        _failure = AcademicFailure.fromException(error);
        _status = AcademicSessionStatus.error;
        rethrow;
      } finally {
        if (!_disposed && generation == _accountGeneration) _notifyListeners();
      }
    });
  }

  Future<LoginResult> _applyLoginResult(
    LoginResult result,
    int generation,
  ) async {
    switch (result) {
      case LoginSuccess(:final studentId):
        _studentId = studentId;
        _serverBindingStatusResolved = true;
        _profile = null;
        _profileStatus = AcademicProfileStatus.loading;
        _captchaChallenge = null;
        _failure = null;
        _status = AcademicSessionStatus.authenticated;
        _notifyListeners();
        // Profile 是显式的第二步请求；登录成功不会因为 Profile 暂时失败而
        // 丢弃已经建立的学校 Session。
        try {
          final profile = await _repository.getProfile();
          if (generation != _accountGeneration || _disposed) {
            return const LoginPageChanged(message: '教务账号上下文已切换');
          }
          _profile = profile;
          _profileStatus = AcademicProfileStatus.loaded;
        } catch (error) {
          if (generation != _accountGeneration || _disposed) {
            return const LoginPageChanged(message: '教务账号上下文已切换');
          }
          final failure = AcademicFailure.fromException(error);
          _profileStatus = AcademicProfileStatus.error;
          _failure = failure;
          if (failure.kind == AcademicFailureKind.sessionExpired) {
            _status = AcademicSessionStatus.error;
            _notifyListeners();
            return LoginPageChanged(message: failure.message);
          }
        }
        try {
          await _persistSessionArtifact(generation);
        } catch (_) {
          // 会话已被学校确认；本地 Artifact 写入失败时下次按凭据重新登录。
        }
        _status = AcademicSessionStatus.authenticated;
        _notifyListeners();
        return result;
      case CaptchaRequired():
        _status = AcademicSessionStatus.awaitingCaptcha;
        _failure = AcademicFailure.fromLoginResult(result);
        _notifyListeners();
        try {
          _captchaChallenge = await _repository.getCaptchaChallenge();
          _pendingAcademicChallenge = _newPendingChallenge();
          if (generation != _accountGeneration || _disposed) {
            return const CaptchaExpired(message: '教务账号上下文已切换');
          }
          _failure = null;
        } catch (error) {
          if (generation != _accountGeneration || _disposed) {
            return const CaptchaExpired(message: '教务账号上下文已切换');
          }
          final failure = AcademicFailure.fromException(error);
          _failure = failure;
          if (_shouldLeaveCaptchaState(failure)) {
            _captchaChallenge = null;
            _status = AcademicSessionStatus.error;
          }
        }
        if (_status != AcademicSessionStatus.error) {
          _status = AcademicSessionStatus.awaitingCaptcha;
        }
        _notifyListeners();
        return result;
      case InvalidCredentials():
      case CaptchaExpired():
      case LoginPageChanged():
      case NetworkUnavailable():
        _captchaChallenge = null;
        _failure = AcademicFailure.fromLoginResult(result);
        _status = AcademicSessionStatus.error;
        _notifyListeners();
        return result;
    }
  }

  LoginResult _handleLoginException(
    Object error,
    int generation, {
    required String stage,
  }) {
    _recordLoginException(stage, error);
    if (generation != _accountGeneration || _disposed) {
      return const LoginPageChanged(message: '教务账号上下文已切换');
    }
    final failure = AcademicFailure.fromException(error);
    _captchaChallenge = null;
    _pendingAcademicChallenge = null;
    _failure = failure;
    _status = AcademicSessionStatus.error;
    _notifyListeners();
    return _loginResultForFailure(failure);
  }

  /// 只记录阶段、Dart 类型和内部白名单错误码，严禁输出密码、Cookie、
  /// 学号、请求体、响应体或异常文本。
  void _recordLoginException(String stage, Object error) {
    final code = switch (error) {
      AcademicFailure(:final code) => _safeLoginDiagnosticCode(code),
      AcademicAuthFailure(:final providerCode, :final type) =>
        _safeLoginDiagnosticCode(
          providerCode ?? 'ACADEMIC_AUTH_${type.name.toUpperCase()}',
        ),
      JiaowuException(:final code) => _safeLoginDiagnosticCode(code),
      _ => 'UNKNOWN',
    };
    debugPrint(
      '教务登录诊断 stage=$stage runtimeType=${error.runtimeType} code=$code',
    );
  }

  String _safeLoginDiagnosticCode(String? value) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty ||
        normalized.length > 64 ||
        !RegExp(r'^[A-Z0-9_]+$').hasMatch(normalized)) {
      return 'UNKNOWN';
    }
    return normalized;
  }

  LoginResult _loginResultForFailure(AcademicFailure failure) {
    return switch (failure.kind) {
      AcademicFailureKind.invalidCredentials =>
        InvalidCredentials(message: failure.message),
      AcademicFailureKind.captchaRequired =>
        CaptchaRequired(message: failure.message),
      AcademicFailureKind.captchaExpired =>
        CaptchaExpired(message: failure.message),
      AcademicFailureKind.network || AcademicFailureKind.schoolUnavailable => NetworkUnavailable(
          message: failure.message,
          cause: NetworkException(
            message: failure.message,
            code: failure.code,
            diagnostic: failure.diagnostic,
          ),
        ),
      _ => LoginPageChanged(message: failure.message),
    };
  }

  bool _shouldLeaveCaptchaState(AcademicFailure failure) {
    return switch (failure.kind) {
      AcademicFailureKind.captchaExpired ||
      AcademicFailureKind.challengeRejected ||
      AcademicFailureKind.authRejectedAmbiguous ||
      AcademicFailureKind.accountRejected ||
      AcademicFailureKind.accountRestricted ||
      AcademicFailureKind.identityMismatch ||
      AcademicFailureKind.disconnected ||
      AcademicFailureKind.localCredentialRequired ||
      AcademicFailureKind.sessionExpired ||
      AcademicFailureKind.unauthenticated ||
      AcademicFailureKind.protocolChanged ||
      AcademicFailureKind.unexpected =>
        true,
      AcademicFailureKind.invalidCredentials ||
      AcademicFailureKind.captchaRequired ||
      AcademicFailureKind.network ||
      AcademicFailureKind.schoolUnavailable ||
      AcademicFailureKind.courseUnavailable ||
      AcademicFailureKind.gradeUnavailable =>
        false,
    };
  }

  bool _canReadAcademicData() {
    if (_appUserId == null) {
      _failure = const AcademicFailure(
        kind: AcademicFailureKind.unauthenticated,
        message: '请先登录 APP',
        code: 'APP_UNAUTHENTICATED',
      );
      _status = AcademicSessionStatus.error;
      _notifyListeners();
      return false;
    }
    if (!isAuthenticated) {
      _failure = AcademicFailure.fromException(
        _repository.sessionState == SessionState.expired
            ? const SessionExpiredException()
            : const UnauthenticatedException(),
      );
      _status = AcademicSessionStatus.error;
      _notifyListeners();
      return false;
    }
    return true;
  }

  Future<bool> _prepareRead(int generation) async {
    if (!await remoteAccessAllowed()) return false;
    if (_connectionPreference == AcademicConnectionPreference.disconnected) {
      _failure = const AcademicFailure(
        kind: AcademicFailureKind.disconnected,
        message: '本机教务已断开，请先重新连接',
        code: 'ACADEMIC_DISCONNECTED',
      );
      _status = AcademicSessionStatus.error;
      _notifyListeners();
      return false;
    }
    if (_appUserId == null) return _canReadAcademicData();
    if (isAuthenticated) return true;
    if (_repository.sessionState == SessionState.expired) {
      final restored = await ensureAuthenticated();
      if (restored && generation == _accountGeneration) return true;
    }
    return _canReadAcademicData();
  }

  void _handleDataFailure(Object error, int generation) {
    if (generation != _accountGeneration || _disposed) return;
    _failure = AcademicFailure.fromException(error);
    _status = isAuthenticated
        ? AcademicSessionStatus.authenticated
        : AcademicSessionStatus.error;
    _notifyListeners();
  }

  void _handleProfileFailure(Object error, int generation) {
    if (generation != _accountGeneration || _disposed) return;
    _profileStatus = AcademicProfileStatus.error;
    _failure = AcademicFailure.fromException(error);
    // 认证会话与资料页面是两个独立边界：资料失败时保留有效会话，
    // 让课表/成绩仍可使用，同时由 UI 明确提示资料需要重试。
    _status = isAuthenticated
        ? AcademicSessionStatus.authenticated
        : AcademicSessionStatus.error;
    _notifyListeners();
  }

  Future<void> _persistSessionArtifact(int generation) async {
    if (!isCurrentContext(generation: generation)) return;
    final activeProvider = provider;
    final currentIdentity = identity;
    final vaultFactory = _sessionArtifactVaultFactory;
    if (activeProvider == null ||
        currentIdentity == null ||
        vaultFactory == null) {
      return;
    }
    final artifact = await activeProvider.exportSession();
    if (artifact == null || !isCurrentContext(generation: generation)) return;
    await vaultFactory(currentIdentity).write(artifact);
  }

  void _clearViewState(AcademicSessionStatus? nextStatus) {
    _studentId = null;
    _profile = null;
    _profileStatus = AcademicProfileStatus.idle;
    _captchaChallenge = null;
    _lastCourses = null;
    _lastGrades = null;
    _failure = null;
    if (nextStatus != null) _status = nextStatus;
  }

  PendingAcademicChallenge? _newPendingChallenge() {
    final identity = this.identity;
    if (identity == null || _captchaChallenge == null) return null;
    return PendingAcademicChallenge(
      challengeId: '${identity.storageId}:$_accountGeneration:${DateTime.now().microsecondsSinceEpoch}',
      identity: identity,
      generation: _accountGeneration,
      createdAt: DateTime.now().toUtc(),
    );
  }

  /// 凭据等最终写入与 Session 清理共用队列，清理完成后不会有旧写入复活。
  Future<T> commit<T>(Future<T> Function() operation) => _enqueue(operation);

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _operationTail;
    _operationTail = previous.then<void>(
      (_) => _runQueued(operation, completer),
      onError: (Object _, StackTrace __) => _runQueued(operation, completer),
    );
    return completer.future;
  }

  Future<void> _runQueued<T>(
    Future<T> Function() operation,
    Completer<T> completer,
  ) async {
    try {
      completer.complete(await operation());
    } catch (error, stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    }
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cleanupCoordinator.unregister(this);
    super.dispose();
  }
}
