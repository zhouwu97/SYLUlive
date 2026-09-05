import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import '../../../services/account_session_cleanup_coordinator.dart';
import '../domain/academic_failure.dart';
import '../domain/academic_repository.dart';

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
    required AcademicRepository repository,
    AccountSessionCleanupCoordinator? cleanupCoordinator,
  })  : _repository = repository,
        _cleanupCoordinator =
            cleanupCoordinator ?? AccountSessionCleanupCoordinator.instance {
    _cleanupCoordinator.register(this, resetSession);
  }

  final AcademicRepository _repository;
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
  bool _disposed = false;

  String? get appUserId => _appUserId;
  int get contextGeneration => _accountGeneration;

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
      !_sessionResetPending &&
      _repository.sessionState == SessionState.authenticated;
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

    _appUserId = next;
    final generation = ++_accountGeneration;
    _sessionResetPending = true;
    _clearViewState(AcademicSessionStatus.idle);
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
        return _handleLoginException(error, generation);
      }
    });
  }

  Future<LoginResult> continueLoginWithCaptcha({required String code}) {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (_disposed) {
        return const CaptchaExpired(message: '教务会话控制器已关闭');
      }
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
        return _handleLoginException(error, generation);
      }
    });
  }

  Future<void> refreshCaptcha() {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (_disposed) return;
      _status = AcademicSessionStatus.awaitingCaptcha;
      _failure = null;
      _notifyListeners();
      try {
        final challenge = await _repository.getCaptchaChallenge();
        if (generation != _accountGeneration || _disposed) return;
        _captchaChallenge = challenge;
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
      if (!_canReadAcademicData()) return null;
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
  }) {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (!_canReadAcademicData()) return null;
      _status = AcademicSessionStatus.loading;
      _failure = null;
      _notifyListeners();
      try {
        final courses = await _repository.getCourses(
          year: year,
          semester: semester,
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

  Future<GradeFetchResult?> loadGrades({
    required String year,
    required int semester,
  }) {
    final generation = _accountGeneration;
    return _enqueue(() async {
      if (!_canReadAcademicData()) return null;
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
      if (!_canReadAcademicData()) return null;
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
      if (!_canReadAcademicData()) return null;
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
      if (!_canReadAcademicData()) return null;
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

  /// 清理学校会话，但保留当前 App 用户上下文。
  Future<void> resetSession() {
    final generation = ++_accountGeneration;
    _sessionResetPending = true;
    _clearViewState(AcademicSessionStatus.idle);
    _notifyListeners();
    return _enqueue(() async {
      if (_disposed) return;
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

  Future<LoginResult> _applyLoginResult(
    LoginResult result,
    int generation,
  ) async {
    switch (result) {
      case LoginSuccess(:final studentId):
        _studentId = studentId;
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
        _status = AcademicSessionStatus.authenticated;
        _notifyListeners();
        return result;
      case CaptchaRequired():
        _status = AcademicSessionStatus.awaitingCaptcha;
        _failure = AcademicFailure.fromLoginResult(result);
        _notifyListeners();
        try {
          _captchaChallenge = await _repository.getCaptchaChallenge();
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

  LoginResult _handleLoginException(Object error, int generation) {
    if (generation != _accountGeneration || _disposed) {
      return const LoginPageChanged(message: '教务账号上下文已切换');
    }
    final failure = AcademicFailure.fromException(error);
    _captchaChallenge = null;
    _failure = failure;
    _status = AcademicSessionStatus.error;
    _notifyListeners();
    return _loginResultForFailure(failure);
  }

  LoginResult _loginResultForFailure(AcademicFailure failure) {
    return switch (failure.kind) {
      AcademicFailureKind.invalidCredentials =>
        InvalidCredentials(message: failure.message),
      AcademicFailureKind.captchaRequired =>
        CaptchaRequired(message: failure.message),
      AcademicFailureKind.captchaExpired =>
        CaptchaExpired(message: failure.message),
      AcademicFailureKind.network => NetworkUnavailable(
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
      AcademicFailureKind.sessionExpired ||
      AcademicFailureKind.unauthenticated ||
      AcademicFailureKind.protocolChanged ||
      AcademicFailureKind.unexpected =>
        true,
      AcademicFailureKind.invalidCredentials ||
      AcademicFailureKind.captchaRequired ||
      AcademicFailureKind.network ||
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
