import 'local_school_profile.dart';
import 'local_school_vault.dart';

enum LocalSchoolSessionState {
  idle,
  loggingIn,
  active,
  relogging,
  expired,
  loggedOut,
}

class LocalSchoolSessionExpiredException implements Exception {
  const LocalSchoolSessionExpiredException([this.message = '学校会话已过期']);

  final String message;

  @override
  String toString() => 'LocalSchoolSessionExpiredException($message)';
}

class LocalSchoolSessionException implements Exception {
  const LocalSchoolSessionException(this.message);

  final String message;

  @override
  String toString() => 'LocalSchoolSessionException($message)';
}

typedef LocalSchoolLoginAction = Future<LocalSchoolCredentials> Function(
  LocalSchoolProfile profile,
  String password,
);
typedef LocalSchoolReloginAction = Future<LocalSchoolCredentials> Function(
  LocalSchoolProfile profile,
);

/// 本地学校会话状态机。
///
/// 过期请求共享一个 relogin Future，其余请求只等待该 Future，不会并发弹出
/// 多个登录流程。切换账号必须由调用方显式创建新的 Manager/Profile。
class LocalSchoolSessionManager {
  LocalSchoolSessionManager({
    required this.profile,
    required this.vault,
    LocalSchoolLoginAction? loginAction,
    LocalSchoolReloginAction? reloginAction,
  })  : _loginAction = loginAction,
        _reloginAction = reloginAction;

  final LocalSchoolProfile profile;
  final LocalSchoolCredentialVault vault;
  final LocalSchoolLoginAction? _loginAction;
  final LocalSchoolReloginAction? _reloginAction;

  LocalSchoolSessionState _state = LocalSchoolSessionState.idle;
  Future<void>? _reloginFuture;
  bool _disposed = false;
  int _operationGeneration = 0;

  LocalSchoolSessionState get state => _state;
  bool get isActive => _state == LocalSchoolSessionState.active;
  Future<void>? get inFlightRelogin => _reloginFuture;

  Future<void> login(
      {required String password, bool rememberPassword = false}) async {
    _ensureUsable();
    if (password.isEmpty) {
      throw const LocalSchoolSessionException('学校密码不能为空');
    }
    final action = _loginAction;
    if (action == null) {
      throw const LocalSchoolSessionException('本地学校登录器未配置');
    }
    final generation = _operationGeneration;
    _state = LocalSchoolSessionState.loggingIn;
    try {
      final credentials = await action(profile, password);
      _ensureCurrentOperation(generation);
      await vault.writeCredentials(
        studentId: credentials.studentId,
        password: password,
        cookie: credentials.cookie,
        sessionMetadata: credentials.sessionMetadata,
        rememberPassword: rememberPassword,
      );
      _ensureCurrentOperation(generation);
      _state = LocalSchoolSessionState.active;
    } catch (error) {
      if (_isCurrentOperation(generation)) {
        _state = LocalSchoolSessionState.expired;
      }
      rethrow;
    }
  }

  /// 将当前会话标记为过期；不会自动使用密码或发起网络请求。
  void markExpired() {
    if (_disposed) return;
    _state = LocalSchoolSessionState.expired;
  }

  /// 共享的单航班重新登录 Future。
  Future<void> relogin() {
    _ensureUsable();
    final existing = _reloginFuture;
    if (existing != null) return existing;
    final action = _reloginAction;
    if (action == null) {
      _state = LocalSchoolSessionState.expired;
      return Future<void>.error(
        const LocalSchoolSessionException('重新登录需要用户明确提供凭据'),
      );
    }
    _state = LocalSchoolSessionState.relogging;
    final future = _performRelogin(action, _operationGeneration);
    _reloginFuture = future;
    return future.whenComplete(() {
      if (identical(_reloginFuture, future)) _reloginFuture = null;
    });
  }

  Future<T> execute<T>(Future<T> Function() operation) async {
    _ensureUsable();
    // 只有明确的 Expired/Relogging 状态允许尝试恢复；Idle 和 LoggedOut
    // 代表用户尚未登录或已主动退出，不能隐式弹出凭据流程。
    if (!isActive) {
      if (_state != LocalSchoolSessionState.expired &&
          _state != LocalSchoolSessionState.relogging) {
        throw const LocalSchoolSessionExpiredException();
      }
      await relogin();
    }
    try {
      return await operation();
    } on LocalSchoolSessionExpiredException {
      await relogin();
      return operation();
    }
  }

  /// [execute] 的语义别名，便于网络层表达“带会话执行”。
  Future<T> run<T>(Future<T> Function() operation) => execute(operation);

  Future<void> logout({bool deleteProfile = false}) async {
    if (_disposed) return;
    _disposed = true;
    _operationGeneration++;
    _state = LocalSchoolSessionState.loggedOut;
    _reloginFuture = null;
    if (deleteProfile) {
      await vault.deleteProfile();
    } else {
      await vault.clear();
      await vault.close();
    }
  }

  Future<void> _performRelogin(
    LocalSchoolReloginAction action,
    int generation,
  ) async {
    try {
      final credentials = await action(profile);
      _ensureCurrentOperation(generation);
      final previous = await vault.read();
      _ensureCurrentOperation(generation);
      final rememberPassword =
          previous?.sessionMetadata['remember_password'] == true ||
              previous?.password != null;
      await vault.writeCredentials(
        studentId: credentials.studentId,
        password: credentials.password,
        cookie: credentials.cookie,
        sessionMetadata: credentials.sessionMetadata,
        // 重新登录不会擅自改变用户原有的“记住密码”决定。
        rememberPassword: rememberPassword,
      );
      _ensureCurrentOperation(generation);
      _state = LocalSchoolSessionState.active;
    } catch (error) {
      if (_isCurrentOperation(generation)) {
        _state = LocalSchoolSessionState.expired;
      }
      rethrow;
    }
  }

  bool _isCurrentOperation(int generation) =>
      !_disposed && generation == _operationGeneration;

  void _ensureCurrentOperation(int generation) {
    if (!_isCurrentOperation(generation)) {
      throw const LocalSchoolSessionException('本地学校会话已注销');
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw const LocalSchoolSessionException('本地学校会话已注销');
    }
  }
}

typedef LocalAcademicSessionManager = LocalSchoolSessionManager;
