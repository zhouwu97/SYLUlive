import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../models/user.dart';
import '../services/account_session_cleanup_coordinator.dart';
import '../platform/contracts/secure_store.dart';
import '../platform/contracts/system_notification_client.dart';
import '../platform/contracts/push_client.dart';
import '../utils/app_feedback.dart';
import '../utils/app_navigator.dart';
import '../services/wallpaper_prefetch_service.dart';
import '../services/keep_alive_service.dart';
import '../services/diagnostic_log_service.dart';
import '../services/diagnostic_dio_interceptor.dart';
import '../services/forbidden_recovery_router.dart';
import '../widgets/auth_expired_overlay.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';
import '../platform/app_platform.dart';

enum AuthState {
  unknown,
  loading,
  authenticated,
  guest,
  recovering,
  recoveryFailed,
  expired
}

/// 认证结果，包含成功状态和错误信息
class AuthResult {
  final bool success;
  final String? errorMessage;
  final int? statusCode;

  const AuthResult({required this.success, this.errorMessage, this.statusCode});

  factory AuthResult.success() => const AuthResult(success: true);

  factory AuthResult.failure(String message, {int? statusCode}) =>
      AuthResult(success: false, errorMessage: message, statusCode: statusCode);
}

/// 注册时提交的法律文件确认。服务端会校验并持久化每份文件的同意记录。
class RegistrationConsents {
  final bool userAgreementAccepted;
  final bool privacyPolicyAccepted;
  final bool communityRulesAccepted;
  final bool minorProtectionAccepted;
  final bool contentComplaintAccepted;
  final bool sdkDisclosureAccepted;
  final bool eduDataConsentAccepted;

  const RegistrationConsents({
    required this.userAgreementAccepted,
    required this.privacyPolicyAccepted,
    required this.communityRulesAccepted,
    required this.minorProtectionAccepted,
    required this.contentComplaintAccepted,
    required this.sdkDisclosureAccepted,
    this.eduDataConsentAccepted = false,
  });

  Map<String, bool> toJson() => {
        'user_agreement_accepted': userAgreementAccepted,
        'privacy_policy_accepted': privacyPolicyAccepted,
        'community_rules_accepted': communityRulesAccepted,
        'minor_protection_accepted': minorProtectionAccepted,
        'content_complaint_accepted': contentComplaintAccepted,
        'sdk_disclosure_accepted': sdkDisclosureAccepted,
        'edu_data_consent_accepted': eduDataConsentAccepted,
      };
}

class StoredAuthCredentials {
  final String? token;
  final String? userJson;

  const StoredAuthCredentials({this.token, this.userJson});
}

abstract interface class PreferenceStore {
  String? getString(String key);

  Future<bool> setString(String key, String value);

  Future<bool> remove(String key);
}

class AuthCredentialConsistencyException implements Exception {
  final String message;
  final Object operationError;
  final Object rollbackError;

  const AuthCredentialConsistencyException({
    required this.message,
    required this.operationError,
    required this.rollbackError,
  });

  @override
  String toString() => message;
}

abstract interface class AuthCredentialStore {
  Future<StoredAuthCredentials> read();

  Future<void> write({required String token, required String userJson});

  Future<void> clear();
}

class PreferenceAuthCredentialStore implements AuthCredentialStore {
  static const _tokenKey = 'auth_token';
  static const _userKey = 'auth_user';

  final PreferenceStore _preferences;

  const PreferenceAuthCredentialStore(this._preferences);

  @override
  Future<StoredAuthCredentials> read() async {
    return StoredAuthCredentials(
      token: _preferences.getString(_tokenKey),
      userJson: _preferences.getString(_userKey),
    );
  }

  @override
  Future<void> write({required String token, required String userJson}) async {
    final oldToken = _preferences.getString(_tokenKey);
    final oldUserJson = _preferences.getString(_userKey);
    try {
      await _setString(_tokenKey, token, '写入认证令牌失败');
      await _setString(_userKey, userJson, '写入认证用户失败');
    } catch (error, stackTrace) {
      try {
        await _restore(_tokenKey, oldToken);
        await _restore(_userKey, oldUserJson);
      } catch (rollbackError) {
        throw AuthCredentialConsistencyException(
          message: '回滚认证信息失败，持久化凭据可能不一致',
          operationError: error,
          rollbackError: rollbackError,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> clear() async {
    final oldToken = _preferences.getString(_tokenKey);
    final oldUserJson = _preferences.getString(_userKey);
    try {
      await _remove(_tokenKey, '删除认证令牌失败');
      await _remove(_userKey, '删除认证用户失败');
    } catch (error, stackTrace) {
      try {
        await _restore(_tokenKey, oldToken);
        await _restore(_userKey, oldUserJson);
      } catch (rollbackError) {
        throw AuthCredentialConsistencyException(
          message: '回滚认证清理失败，持久化凭据可能不一致',
          operationError: error,
          rollbackError: rollbackError,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _setString(String key, String value, String message) async {
    if (!await _preferences.setString(key, value)) {
      throw StateError(message);
    }
  }

  Future<void> _remove(String key, String message) async {
    if (!await _preferences.remove(key)) throw StateError(message);
  }

  Future<void> _restore(String key, String? value) async {
    final restored = value == null
        ? await _preferences.remove(key)
        : await _preferences.setString(key, value);
    if (!restored) throw StateError('回滚偏好设置失败: $key');
  }
}

/// 通过鸿蒙 Asset Store Kit 持久化登录令牌。
///
/// 原生端不设置“卸载后保留”标记，删除应用会一并清除这些凭据。
class _PlatformAuthCredentialStore implements AuthCredentialStore {
  static const _tokenKey = 'auth_token';
  static const _userKey = 'auth_user';

  final AppSecretStore _store = AppSecretStore.current();
  Future<AppPreferencesStore> get _prefs => AppPreferencesStore.getInstance();

  @override
  Future<StoredAuthCredentials> read() async {
    final prefs = await _prefs;
    return StoredAuthCredentials(
      token: await _store.read(_tokenKey),
      userJson: prefs.getString(_userKey),
    );
  }

  @override
  Future<void> write({required String token, required String userJson}) async {
    final prefs = await _prefs;
    final oldToken = await _store.read(_tokenKey);
    final oldUserJson = prefs.getString(_userKey);
    try {
      await _store.write(_tokenKey, token);
      if (!await prefs.setString(_userKey, userJson)) {
        throw StateError('用户信息持久化失败');
      }
    } catch (error, stackTrace) {
      try {
        await _restore(_tokenKey, oldToken);
        if (oldUserJson == null) {
          if (!await prefs.remove(_userKey)) {
            throw StateError('回滚用户信息删除失败');
          }
        } else {
          if (!await prefs.setString(_userKey, oldUserJson)) {
            throw StateError('回滚用户信息修改失败');
          }
        }
      } catch (rollbackError) {
        throw AuthCredentialConsistencyException(
          message: '回滚认证信息失败，持久化凭据可能不一致',
          operationError: error,
          rollbackError: rollbackError,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> clear() async {
    final prefs = await _prefs;
    try {
      await Future.wait([
        _store.delete(_tokenKey),
        prefs.remove(_userKey),
      ]);
    } catch (e) {
      debugPrint('清除凭据遇到异常: $e');
    }
  }

  Future<void> _restore(String key, String? value) async {
    if (value == null) {
      await _store.delete(key);
    } else {
      await _store.write(key, value);
    }
  }
}

class _AuthSessionCandidate {
  final String token;
  final User user;

  const _AuthSessionCandidate(this.token, this.user);
}

class AuthProvider extends ChangeNotifier {
  final Dio _dio;
  final AuthCredentialStore _credentialStore;
  final bool _usesPlatformCredentialStore;
  final VoidCallback _onAuthenticated;
  final AccountSessionCleanupCoordinator _sessionCleanupCoordinator;
  final void Function(ForbiddenRecoveryRoute route)? _onForbiddenRecovery;
  User? _user;
  String? _token;
  bool _isLoading = false;
  bool _initialized = false;
  Future<void>? _initializationFuture;
  Future<void>? _sessionExpiryFuture;
  Future<void> _authMutationTail = Future<void>.value();
  int _sessionGeneration = 0;
  int _accountSessionEpoch = 0;
  bool _applyingConsentRestriction = false;
  AuthState _authState = AuthState.unknown;
  ForbiddenRecoveryRoute? _lastForbiddenRecovery;

  User? get user => _user;
  String? get token => _token;
  AuthState get authState => _authState;
  bool get isLoading => _isLoading;
  bool get isLoggedIn => _authState == AuthState.authenticated;
  bool get isInitialized => _initialized;
  ForbiddenRecoveryRoute? get lastForbiddenRecovery => _lastForbiddenRecovery;

  void _setAuthState(AuthState state) {
    if (_authState != state) {
      _authState = state;
      notifyListeners();
    }
  }

  int get sessionGeneration => _sessionGeneration;
  int get accountSessionEpoch => _accountSessionEpoch;
  Dio get dio => _dio;
  PersistCookieJar? _cookieJar;

  AuthProvider(
    this._dio, {
    AuthCredentialStore? credentialStore,
    bool loadStoredAuth = true,
    VoidCallback? onAuthenticated,
    AccountSessionCleanupCoordinator? sessionCleanupCoordinator,
    void Function(ForbiddenRecoveryRoute route)? onForbiddenRecovery,
  })  : _credentialStore = credentialStore ?? _PlatformAuthCredentialStore(),
        _usesPlatformCredentialStore = credentialStore == null,
        _onAuthenticated = onAuthenticated ?? WallpaperPrefetchService.start,
        _sessionCleanupCoordinator = sessionCleanupCoordinator ??
            AccountSessionCleanupCoordinator.instance,
        _onForbiddenRecovery = onForbiddenRecovery {
    // 添加 401 拦截器：自动登出并提示重新登录
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final token = _token;
          options.extra['authSessionGeneration'] = _sessionGeneration;
          options.extra['authTokenFingerprint'] = _tokenFingerprint(token);
          // Web 端凭据只存在 HttpOnly Cookie，内存中没有 JWT，因此用当前用户
          // 标记请求是否属于已认证会话，确保 Cookie 会话失效时能够收口。
          options.extra['requestHadAuth'] =
              (token != null && token.isNotEmpty) || (kIsWeb && _user != null);
          if (token != null && token.isNotEmpty) {
            // 将凭据写入本次请求，避免全局 headers 在异步切换会话时串值。
            options.headers['Authorization'] = 'Bearer $token';
          } else {
            options.headers.remove('Authorization');
          }
          handler.next(options);
        },
        onError: (error, handler) {
          final status = error.response?.statusCode;
          final responseBody = error.response?.data;
          final errorCode = responseBody is Map ? responseBody['code'] : null;
          final rawPath = error.requestOptions.path;
          final uriPath = error.requestOptions.uri.path;

          final isEduApi = rawPath.startsWith('/edu/') ||
              uriPath.startsWith('/edu/') ||
              uriPath.startsWith('/api/edu/');

          final requestHadAuth =
              error.requestOptions.extra['requestHadAuth'] == true;
          final requestGeneration =
              error.requestOptions.extra['authSessionGeneration'];
          final requestFingerprint =
              error.requestOptions.extra['authTokenFingerprint'];
          final isCurrentSessionRequest = requestHadAuth &&
              requestGeneration == _sessionGeneration &&
              requestFingerprint == _tokenFingerprint(_token);

          if (status == 401 && requestHadAuth) {
            if (isEduApi) {
              // 教务会话失效不导致 App 登录失效
              handler.next(error);
              return;
            }

            // 非教务接口，判定为 App 401
            final isTargetError = errorCode == 'invalid_token' ||
                errorCode == 'token_version_expired' ||
                errorCode == 'authentication_required' ||
                errorCode == 'role_changed';

            if (!isTargetError || !isCurrentSessionRequest) {
              // 未分类业务 401，以及旧会话请求的 401，都不能清除当前会话。
              if (isTargetError && !isCurrentSessionRequest) {
                debugPrint(
                    '忽略旧会话 401: requestGen=$requestGeneration currentGen=$_sessionGeneration');
              }
              handler.next(error);
              return;
            }

            debugPrint('检测到 App 401，自动登出');
            DiagnosticLogService.instance.record(
              level: 'warning',
              source: '账号',
              type: '登录状态已过期',
              summary: '服务器拒绝当前登录凭据，应用将退出登录',
              detail: 'HTTP 401\ncode=${errorCode ?? "unknown"}',
              eventCode: 'auth_token_expired',
              category: 'auth',
              operation: 'expire',
              result: 'failure',
              httpStatus: 401,
              route: normalizeDiagnosticRoute(error.requestOptions.uri.path),
              metadata: <String, Object?>{
                'errorCode': errorCode?.toString() ?? 'unknown',
              },
            );
            _expireCurrentSession(_sessionGeneration, _token);
            // 重置 overlay 标记，允许再次弹出
            AuthExpiredManager.resetSessionFlag();
            // 延迟一帧弹出重新登录提示
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _showAuthExpiredOverlay();
            });
          }
          if (status == 403 &&
              requestHadAuth &&
              isCurrentSessionRequest &&
              (_token != null || (kIsWeb && _user != null))) {
            _handleForbiddenRecovery(errorCode);
          }
          handler.next(error);
        },
      ),
    );
    if (loadStoredAuth) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => initializeStoredAuth(),
      );
    }
  }

  static String? _tokenFingerprint(String? token) {
    if (token == null || token.isEmpty) return null;
    return sha256.convert(utf8.encode(token)).toString().substring(0, 8);
  }

  Future<T> _enqueueAuthMutation<T>(Future<T> Function() mutation) {
    final next = _authMutationTail.then((_) => mutation());
    _authMutationTail = next.then<void>((_) {}, onError: (_, __) {});
    return next;
  }

  Future<void> _expireCurrentSession(int generation, String? token) {
    if (_sessionExpiryFuture != null) return _sessionExpiryFuture!;
    _sessionExpiryFuture = _enqueueAuthMutation(() async {
      if (_sessionGeneration != generation || _token != token) return;
      await _clearLocalSession(
        clearPushAlias: true,
        closeAccountContext: true,
        expectedGeneration: generation,
        expectedToken: token,
        skipMutationQueue: true,
      );
    }).whenComplete(() => _sessionExpiryFuture = null);
    return _sessionExpiryFuture!;
  }

  Future<void> initializeStoredAuth() {
    return _initializationFuture ??= _loadStoredAuth();
  }

  void _applyAuthHeader() {
    if (_token != null && _token!.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $_token';
    } else {
      _dio.options.headers.remove('Authorization');
    }
  }

  Future<void> _initCookieJar() async {
    if (!kIsWeb && _cookieJar == null) {
      final appDocDir = await getApplicationDocumentsDirectory();
      final appDocPath = appDocDir.path;
      _cookieJar = PersistCookieJar(
        ignoreExpires: true,
        storage: FileStorage('$appDocPath/.cookies/'),
      );
      // 完全关闭原生 Cookie 写入，仅保留清理逻辑
      await _cookieJar!.deleteAll();
    }
  }

  Future<void> _loadStoredAuth() async {
    final stopwatch = Stopwatch()..start();
    var shouldClearCorruptedCredentials = false;
    _setAuthState(AuthState.loading);
    try {
      AppPreferencesStore? prefs;
      if (_usesPlatformCredentialStore) {
        await _initCookieJar();
        prefs = await AppPreferencesStore.getInstance();
        // Web 旧版密码位于偏好设置，启动即全量清理；原生端在读取到用户后
        // 以其学号删除历史安全存储键。
        await _clearLegacyEduPasswords(prefs, null);
      }

      if (prefs?.getBool('auth_force_logged_out') == true) {
        await _clearStoredAuth();
        await prefs!.remove('auth_force_logged_out');
        _setAuthState(AuthState.guest);
      } else {
        final stored = await _credentialStore.read();

        if (kIsWeb && stored.userJson != null) {
          // Web 端不恢复 JWT 文本，只用浏览器自动管理的 HttpOnly Cookie 验证会话。
          final response = await _dio.get('/user/profile');
          if (response.statusCode != 200 || response.data is! Map) {
            await _clearStoredAuth();
            _setAuthState(AuthState.guest);
          } else {
            final user =
                User.fromJson(Map<String, dynamic>.from(response.data));
            _user = user;
            _token = null;
            _sessionGeneration++;
            _accountSessionEpoch++;
            _setAuthState(AuthState.authenticated);
            if (user.legalConsentsActive) {
              _onAuthenticated();
            } else {
              await _clearConsentDependentLocalData(user);
            }
          }
        } else if (stored.token != null && stored.userJson != null) {
          // 从这里开始只要解析或校验失败，就说明两项凭据已形成损坏组合。
          // 网络恢复失败（token-only）不走这条路径，避免误删可恢复会话。
          shouldClearCorruptedCredentials = true;
          final decoded = jsonDecode(stored.userJson!);
          if (decoded is! Map) {
            throw const FormatException('本地用户信息不是对象');
          }
          final candidate = _authSessionCandidate(
            stored.token!,
            Map<String, dynamic>.from(decoded),
          );
          if (prefs != null) {
            await _clearLegacyEduPasswords(prefs, candidate.user);
          }
          _commitAuthSession(candidate);
          _setAuthState(AuthState.authenticated);
          DiagnosticLogService.instance.record(
            level: 'info',
            source: '账号',
            type: '登录恢复成功',
            summary: '已从本地安全存储恢复登录状态',
            detail: '',
            eventCode: 'auth_session_restored',
            category: 'auth',
            operation: 'restore',
            result: 'success',
            durationMs: stopwatch.elapsedMilliseconds,
          );
          if (candidate.user.legalConsentsActive) {
            _onAuthenticated();
          } else {
            await _clearConsentDependentLocalData(candidate.user);
          }
        } else if (stored.token != null && stored.userJson == null) {
          _setAuthState(AuthState.recovering);
          final recoveryState = await _recoverUserWithToken(stored.token!);
          _setAuthState(recoveryState);
          if (recoveryState == AuthState.expired) {
            DiagnosticLogService.instance.record(
              level: 'warning',
              source: '账号',
              type: '本地 Token 已过期',
              summary: '启动恢复登录时服务器拒绝了本地凭据',
              detail: '',
              eventCode: 'auth_restore_expired',
              category: 'auth',
              operation: 'restore',
              result: 'failure',
              durationMs: stopwatch.elapsedMilliseconds,
              httpStatus: 401,
            );
            await _clearStoredAuth();
          } else if (recoveryState == AuthState.recoveryFailed) {
            DiagnosticLogService.instance.record(
              level: 'warning',
              source: '账号',
              type: '登录恢复失败',
              summary: '暂时无法向服务器确认本地登录状态',
              detail: '',
              eventCode: 'auth_restore_failed',
              category: 'auth',
              operation: 'restore',
              result: 'retry',
              durationMs: stopwatch.elapsedMilliseconds,
            );
          }
        } else {
          if (stored.userJson != null) {
            await _clearStoredAuth();
          }
          _setAuthState(AuthState.guest);
        }
      }
    } catch (e) {
      debugPrint('解析本地认证信息失败: $e');
      DiagnosticLogService.instance.recordError(
        source: '账号',
        type: '认证缓存读取失败',
        summary: '本地登录信息损坏或无法读取',
        detail: e.toString(),
        eventCode: 'auth_cache_read_failed',
        category: 'auth',
        operation: 'restore',
        result: 'failure',
        durationMs: stopwatch.elapsedMilliseconds,
      );
      if (shouldClearCorruptedCredentials) {
        await _clearCorruptedStoredAuth();
      }
      _setAuthState(AuthState.guest);
    }
    _initialized = true;
    if (_user?.legalConsentsActive ?? false) {
      await KeepAliveService.instance.syncAuthToken(_token);
    }
    notifyListeners();
  }

  Future<AuthState> _recoverUserWithToken(String token) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: _dio.options.baseUrl,
        headers: {'Authorization': 'Bearer $token'},
        connectTimeout: const Duration(seconds: 10),
      ));
      final response = await dio.get('/user/profile');
      if (response.statusCode == 200 && response.data != null) {
        final userJson = Map<String, dynamic>.from(response.data);
        final candidate = _authSessionCandidate(token, userJson);
        await _saveAuthCandidate(candidate);
        _commitAuthSession(candidate);
        _onAuthenticated();
        return AuthState.authenticated;
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        debugPrint('恢复用户状态失败：Token已过期');
        return AuthState.expired;
      }
      debugPrint('恢复用户状态失败（网络错误等）: $e');
    } catch (e) {
      debugPrint('恢复用户状态失败: $e');
    }
    return AuthState.recoveryFailed;
  }

  Future<void> _saveAuthCandidate(_AuthSessionCandidate candidate) async {
    await _enqueueAuthMutation(() async {
      await _credentialStore.write(
        token: candidate.token,
        userJson: jsonEncode(candidate.user.toJson()),
      );
      // 新会话完整落盘后清除旧的退出墓碑，防止下次冷启动被墓碑再次清掉。
      // 墓碑只在平台凭据存储路径下被启动逻辑读取，注入凭据存储（Web/测试）不涉及。
      if (_usesPlatformCredentialStore) {
        final prefs = await AppPreferencesStore.getInstance();
        if (prefs.containsKey('auth_force_logged_out') &&
            !await prefs.remove('auth_force_logged_out')) {
          throw StateError('清除认证退出墓碑失败');
        }
      }
    });
    if (candidate.user.legalConsentsActive) {
      await KeepAliveService.instance.syncAuthToken(candidate.token);
    } else {
      await _clearConsentDependentLocalData(candidate.user);
    }
  }

  Future<void> _clearCorruptedStoredAuth() async {
    try {
      await _clearStoredAuth();
      DiagnosticLogService.instance.record(
        level: 'info',
        source: '账号',
        type: '认证缓存已清理',
        summary: '已清除损坏的本地登录信息',
        detail: '',
        eventCode: 'auth_corrupted_cache_cleared',
        category: 'auth',
        operation: 'restore',
        result: 'success',
      );
    } catch (error, stackTrace) {
      debugPrint('清除损坏认证缓存失败: $error');
      DiagnosticLogService.instance.recordError(
        source: '账号',
        type: '认证缓存清理失败',
        summary: '损坏的本地登录信息无法清除',
        detail: '$error\n\n$stackTrace',
        eventCode: 'auth_corrupted_cache_clear_failed',
        category: 'auth',
        operation: 'restore',
        result: 'failure',
      );
      await _writeForceLoggedOutTombstone();
    }
  }

  Future<void> _writeForceLoggedOutTombstone() async {
    try {
      final prefs = await AppPreferencesStore.getInstance();
      await prefs.setBool('auth_force_logged_out', true);
    } catch (error) {
      debugPrint('写入认证退出墓碑失败: $error');
    }
  }

  void _handleForbiddenRecovery(Object? errorCode) {
    final route = ForbiddenRecoveryRouter.resolve(errorCode);
    if (route == null) return;

    final previous = _lastForbiddenRecovery;
    _lastForbiddenRecovery = route;
    try {
      _onForbiddenRecovery?.call(route);
    } catch (error, stackTrace) {
      debugPrint('执行 403 UI 恢复回调失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    if (route.requiresConsent) {
      unawaited(
        _applyLegalConsentRestriction(required: route.consentIsRequired),
      );
    } else if (previous?.code != route.code) {
      // 管理员权限变化只通知 UI 收口，不把 403 错误升级为退出登录。
      notifyListeners();
    }

    DiagnosticLogService.instance.record(
      level: 'warning',
      source: '权限',
      type: '403 恢复路由',
      summary: '服务端返回受限访问，已进入对应恢复流程',
      detail: 'code=${route.code}',
      eventCode: 'auth_forbidden_recovery',
      category: 'auth',
      operation: 'recover_forbidden',
      result:
          route.requiresConsent ? 'consent_required' : 'admin_ui_restricted',
      httpStatus: 403,
      metadata: <String, Object?>{'errorCode': route.code},
    );
  }

  /// 页面完成对应恢复后调用，避免管理员旧状态一直被视为待处理。
  void clearForbiddenRecovery() {
    if (_lastForbiddenRecovery == null) return;
    _lastForbiddenRecovery = null;
    notifyListeners();
  }

  /// 清理旧版本在本机保存的教务密码。教务凭据只允许由服务端加密保管。
  Future<void> _clearLegacyEduPasswords(
    AppPreferencesStore preferences,
    User? user,
  ) async {
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith('edu_pwd_'))
        .toList(growable: false);
    await Future.wait(keys.map(preferences.remove));

    if (kIsWeb || user == null) return;
    final secretStore = AppSecretStore.current();
    final identifiers = <String>{
      user.studentId.trim(),
      user.eduStudentId.trim(),
    }..removeWhere((value) => value.isEmpty);
    await Future.wait(
      identifiers
          .map((identifier) => secretStore.delete('edu_pwd_$identifier')),
    );
  }

  _AuthSessionCandidate _authSessionCandidate(
    Object? rawToken,
    Map<String, dynamic> userJson,
  ) {
    if (rawToken != null && rawToken is! String) {
      throw const FormatException('认证令牌无效');
    }
    if (!kIsWeb && (rawToken is! String || rawToken.trim().isEmpty)) {
      throw const FormatException('认证令牌无效');
    }
    return _AuthSessionCandidate(
      rawToken is String ? rawToken : '',
      User.fromJson(userJson),
    );
  }

  _AuthSessionCandidate _authSessionCandidateFromResponse(Object? data) {
    if (data is! Map) throw const FormatException('认证响应不是对象');
    final rawUser = data['user'];
    if (rawUser is! Map) throw const FormatException('认证用户不是对象');
    return _authSessionCandidate(
      data['token'],
      Map<String, dynamic>.from(rawUser),
    );
  }

  void _commitAuthSession(_AuthSessionCandidate candidate) {
    // 浏览器不把 JWT 留在持久化层，也不把它重新放进 Authorization 头；
    // 服务端 Set-Cookie 的 HttpOnly 会话负责后续请求认证。
    _token = kIsWeb ? null : candidate.token;
    _user = candidate.user;
    _lastForbiddenRecovery = null;
    _sessionGeneration++;
    _accountSessionEpoch++;
    _applyAuthHeader();
  }

  Future<void> _saveAndCommitAuthSession(
    _AuthSessionCandidate candidate, {
    bool prefetchWallpaper = false,
  }) async {
    await _saveAuthCandidate(candidate);
    if (_user != null && _user!.id != candidate.user.id) {
      await _sessionCleanupCoordinator.closeCurrentSession();
      await _clearAccountNotificationState();
    }
    _commitAuthSession(candidate);
    _setAuthState(AuthState.authenticated);
    if (prefetchWallpaper && candidate.user.legalConsentsActive) {
      _onAuthenticated();
    }
  }

  /// 解析 Dio 异常并返回友好的错误信息。
  String _parseDioError(DioException e) {
    debugPrint(
      '认证请求失败: type=${e.type}, status=${e.response?.statusCode}',
    );
    return AppFeedback.dioErrorMessage(e, fallback: '操作失败，请稍后再试');
  }

  Future<AuthResult> register(
    String studentId,
    String password, {
    String? nickname,
    String? qq,
    RegistrationConsents? consents,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final data = <String, dynamic>{
        'student_id': studentId,
        'password': password,
      };
      if (nickname != null && nickname.isNotEmpty) {
        data['nickname'] = nickname;
      }
      if (qq != null && qq.isNotEmpty) {
        data['qq'] = qq;
      }
      if (consents != null) data.addAll(consents.toJson());
      final response = await _dio.post('/register', data: data);

      _isLoading = false;
      if (response.statusCode == 201) {
        final candidate = _authSessionCandidateFromResponse(response.data);
        await _saveAndCommitAuthSession(candidate, prefetchWallpaper: true);
        notifyListeners();
        return AuthResult.success();
      }
      // 未知状态码
      return AuthResult.failure('注册失败，服务器返回异常');
    } on DioException catch (e) {
      _isLoading = false;
      notifyListeners();
      final errorMsg = _parseDioError(e);
      debugPrint(
        '注册失败: type=${e.type}, status=${e.response?.statusCode}',
      );
      return AuthResult.failure(errorMsg);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      debugPrint('注册异常: ${e.runtimeType}');
      return AuthResult.failure('注册失败');
    }
  }

  Future<AuthResult> login(String account, String password) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await _dio.post(
        '/login',
        data: {'account': account, 'password': password},
      );

      _isLoading = false;
      if (response.statusCode == 200) {
        final candidate = _authSessionCandidateFromResponse(response.data);
        await _saveAndCommitAuthSession(candidate, prefetchWallpaper: true);
        notifyListeners();
        return AuthResult.success();
      }
      return AuthResult.failure('登录失败，服务器返回异常');
    } on DioException catch (e) {
      _isLoading = false;
      notifyListeners();
      final errorMsg = _parseDioError(e);
      debugPrint(
        '登录失败: type=${e.type}, status=${e.response?.statusCode}',
      );
      return AuthResult.failure(errorMsg, statusCode: e.response?.statusCode);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      debugPrint('登录异常: ${e.runtimeType}');
      return AuthResult.failure('登录失败');
    }
  }

  Future<void> logout() async {
    await _sessionCleanupCoordinator.closeCurrentSession();
    try {
      await _dio.post('/logout'); // 调用服务端登出接口
    } catch (e) {
      debugPrint('服务端登出异常: ${e.runtimeType}');
    }
    await _clearLocalSession(
      clearPushAlias: true,
      closeAccountContext: false,
    );
  }

  Future<AuthResult> deleteAccount(String password) async {
    if (!isLoggedIn) {
      return AuthResult.failure('当前未登录');
    }
    _isLoading = true;
    notifyListeners();
    try {
      await _dio.delete(
        '/user/account',
        data: {'password': password, 'confirmed': true},
      );
      await _clearLocalSession(clearPushAlias: true);
      _isLoading = false;
      notifyListeners();
      return AuthResult.success();
    } on DioException catch (e) {
      _isLoading = false;
      notifyListeners();
      return AuthResult.failure(_parseDioError(e),
          statusCode: e.response?.statusCode);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return AuthResult.failure('账号注销失败: $e');
    }
  }

  /// 确认最新法律文件，并以服务端返回的授权状态更新本地会话。
  Future<AuthResult> acceptRequiredLegalConsents({
    required bool includeEduDataConsent,
  }) async {
    if (!isLoggedIn) return AuthResult.failure('当前未登录');
    _isLoading = true;
    notifyListeners();
    try {
      final response = await _dio.post(
        '/user/legal-consents',
        data: {
          'user_agreement_accepted': true,
          'privacy_policy_accepted': true,
          'community_rules_accepted': true,
          'minor_protection_accepted': true,
          'content_complaint_accepted': true,
          'sdk_disclosure_accepted': true,
          'edu_data_consent_accepted': includeEduDataConsent,
        },
      );
      final payload = response.data;
      if (response.statusCode != 200 ||
          payload is! Map ||
          payload['user'] is! Map) {
        return AuthResult.failure('协议确认失败，请稍后重试');
      }
      await applyProfileResponse(
        Map<String, dynamic>.from(payload['user'] as Map),
      );
      _isLoading = false;
      notifyListeners();
      return AuthResult.success();
    } on DioException catch (e) {
      _isLoading = false;
      notifyListeners();
      return AuthResult.failure(
        _parseDioError(e),
        statusCode: e.response?.statusCode,
      );
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return AuthResult.failure('协议确认失败: $e');
    }
  }

  /// 立即撤销全部法律文件授权，并保留当前会话办理隐私权利与账号注销。
  Future<AuthResult> withdrawLegalConsents(String password) async {
    if (!isLoggedIn) return AuthResult.failure('当前未登录');
    _isLoading = true;
    notifyListeners();
    try {
      await _dio.delete(
        '/user/privacy/consents',
        data: {'password': password, 'confirmed': true},
      );
      await _applyLegalConsentRestriction(required: false);
      _isLoading = false;
      notifyListeners();
      return AuthResult.success();
    } on DioException catch (e) {
      _isLoading = false;
      notifyListeners();
      return AuthResult.failure(
        _parseDioError(e),
        statusCode: e.response?.statusCode,
      );
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      return AuthResult.failure('撤销同意失败: $e');
    }
  }

  Future<void> _applyLegalConsentRestriction({required bool required}) async {
    if (_applyingConsentRestriction || _user == null) return;
    if (!_user!.legalConsentsActive &&
        _user!.legalConsentsRequired == required) {
      return;
    }
    _applyingConsentRestriction = true;
    final currentUser = _user!;
    try {
      final userJson = Map<String, dynamic>.from(currentUser.toJson())
        ..['legal_consents_active'] = false
        ..['legal_consents_required'] = required
        ..['edu_bound'] = false
        ..['edu_authorized'] = false
        ..['edu_session_state'] = 'revoked';
      final nextUser = User.fromJson(userJson);
      await _enqueueAuthMutation(() => _credentialStore.write(
            // Web 端只更新已持久化的用户快照，JWT 仍由 HttpOnly Cookie 管理。
            token: _token ?? '',
            userJson: jsonEncode(nextUser.toJson()),
          ));
      _user = nextUser;
      _sessionGeneration++;
      await _clearConsentDependentLocalData(currentUser);
      notifyListeners();
    } catch (e) {
      debugPrint('同步授权受限状态失败: $e');
    } finally {
      _applyingConsentRestriction = false;
    }
  }

  Future<void> _clearConsentDependentLocalData(User user) async {
    await KeepAliveService.instance.syncAuthToken(null);
    await _clearPushAlias();
  }

  /// 统一的本地会话清理
  ///
  /// [clearPushAlias] 为 true 时清理旧版本可能遗留的极光 Alias（手动退出 / 401）。
  Future<void> _clearLocalSession({
    required bool clearPushAlias,
    bool closeAccountContext = true,
    int? expectedGeneration,
    String? expectedToken,
    bool skipMutationQueue = false,
  }) async {
    if (expectedGeneration != null &&
        (_sessionGeneration != expectedGeneration || _token != expectedToken)) {
      return;
    }
    if (!skipMutationQueue) {
      await _enqueueAuthMutation(() => _clearLocalSession(
            clearPushAlias: clearPushAlias,
            closeAccountContext: closeAccountContext,
            expectedGeneration: expectedGeneration,
            expectedToken: expectedToken,
            skipMutationQueue: true,
          ));
      return;
    }
    final hadSession = _token != null || _user != null;
    // 先清除持久化凭据，失败时保留内存会话，避免出现“界面已退出、下次又恢复”的状态。
    await _clearStoredAuth();

    // 写入墓碑，防止下一次启动恢复旧 token。
    try {
      final prefs = await AppPreferencesStore.getInstance();
      await prefs.setBool('auth_force_logged_out', true);
    } catch (_) {}

    // 认证凭据清除成功后再提交内存状态。
    await _clearAccountNotificationState();
    _token = null;
    _user = null;
    _lastForbiddenRecovery = null;
    if (_authState != AuthState.expired) {
      _setAuthState(AuthState.guest);
    }
    if (hadSession) {
      _sessionGeneration++;
      _accountSessionEpoch++;
    }
    _applyAuthHeader();
    notifyListeners();

    if (closeAccountContext) {
      try {
        await _sessionCleanupCoordinator.closeCurrentSession();
      } catch (e) {
        debugPrint('关闭账号上下文失败: $e');
      }
    }

    if (!kIsWeb && _cookieJar != null) {
      try {
        await _cookieJar!.deleteAll();
      } catch (_) {}
    }
    if (clearPushAlias) {
      await _clearPushAlias();
    }
  }

  /// 清理旧版极光 Alias，防止退出后仍收到前用户私信通知；新版本不再创建 Alias。
  Future<void> _clearPushAlias() async {
    try {
      await PushClient.current().clearAlias();
    } catch (e) {
      debugPrint('清除 JPush Alias 失败: ${e.runtimeType}');
    }
    try {
      await const MethodChannel('shenliyuan/private_message_notifications')
          .invokeMethod('clearAlias');
    } catch (e) {
      debugPrint('清除 JPush Alias 失败: ${e.runtimeType}');
    }
  }

  Future<void> _clearAccountNotificationState() async {
    if (!kIsWeb) {
      try {
        await const MethodChannel('shenliyuan/notification_open')
            .invokeMethod('clearPendingNotificationOpen');
      } catch (e) {
        debugPrint('清除账号通知点击队列失败: ${e.runtimeType}');
      }
    }
    try {
      await SystemNotificationClient.current().cancelAll();
    } catch (e) {
      debugPrint('清除账号本地通知失败: ${e.runtimeType}');
    }
  }

  Future<void> _clearStoredAuth() async {
    await _credentialStore.clear();
    await KeepAliveService.instance.syncAuthToken(null);
  }

  void _showAuthExpiredOverlay() {
    final context = appNavigatorKey.currentContext;
    if (context == null) return;
    AuthExpiredManager.show(
      context,
      onDismiss: () {},
      onRelogin: () {
        // 导航到登录页
        appNavigatorKey.currentState?.pushNamed('/login');
      },
    );
  }

  Future<AuthResult> updateProfile(String nickname) async {
    try {
      final response = await _dio.put(
        '/user/profile',
        data: {'nickname': nickname},
      );
      if (response.statusCode == 200) {
        await applyProfileResponse(
          Map<String, dynamic>.from(response.data),
        );
        return AuthResult.success();
      }
      return AuthResult.failure('更新资料失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      debugPrint(
        '更新资料失败: type=${e.type}, status=${e.response?.statusCode}',
      );
      return AuthResult.failure(errorMsg);
    }
  }

  int _profileGeneration = 0;
  Future<void> _profileWriteTail = Future.value();

  /// 从服务器刷新当前用户信息（角色变更后调用）
  Future<void> refreshUser() async {
    if (_user == null) return;
    final generation = ++_profileGeneration;
    try {
      final response = await _dio.get('/user/profile');
      if (response.statusCode == 200) {
        await _enqueueProfileCommit(
          Map<String, dynamic>.from(response.data),
          generation,
        );
      }
    } on DioException catch (e) {
      debugPrint(
        '刷新用户信息失败: type=${e.type}, status=${e.response?.statusCode}',
      );
    }
  }

  Future<void> applyAuthPayload(
    String token,
    Map<String, dynamic> userJson,
  ) async {
    final candidate = _authSessionCandidate(token, userJson);
    await _saveAndCommitAuthSession(candidate, prefetchWallpaper: true);
    notifyListeners();
  }

  Future<void> applyProfileResponse(Map<String, dynamic> userJson) async {
    final generation = ++_profileGeneration;
    await _enqueueProfileCommit(userJson, generation);
  }

  Future<void> _enqueueProfileCommit(
    Map<String, dynamic> userJson,
    int generation,
  ) {
    final commit = _profileWriteTail.then((_) async {
      if (generation != _profileGeneration) return;
      await _commitProfileResponse(userJson);
    });

    // 提交失败不能阻断后续资料响应进入队列。
    _profileWriteTail = commit.then<void>(
      (_) {},
      onError: (_, __) {},
    );
    return commit;
  }

  Future<void> _commitProfileResponse(
    Map<String, dynamic> userJson,
  ) async {
    final token = _token;
    if (token == null) {
      throw StateError('当前登录状态无效');
    }

    final nextUser = User.fromJson(userJson);

    await _enqueueAuthMutation(() => _credentialStore.write(
          token: token,
          userJson: jsonEncode(nextUser.toJson()),
        ));

    _commitUserSnapshot(nextUser);
    notifyListeners();
  }

  void _commitUserSnapshot(User nextUser) {
    _user = nextUser;
    _sessionGeneration++;
    // 不修改 _accountSessionEpoch
  }

  Future<AuthResult> updateAvatar(Uint8List avatarBytes) async {
    try {
      final uploadFormData = FormData.fromMap({
        'file': MultipartFile.fromBytes(avatarBytes, filename: 'avatar.jpg'),
      });
      final uploadResponse = await _dio.post('/upload', data: uploadFormData);

      if (uploadResponse.statusCode != 200 ||
          uploadResponse.data['url'] == null) {
        return AuthResult.failure('头像上传失败');
      }

      final avatarUrl = uploadResponse.data['url'] as String;

      // 步骤2: 更新用户头像URL
      final response = await _dio.put(
        '/user/avatar',
        data: {'avatar': avatarUrl},
      );
      if (response.statusCode == 200) {
        // 刷新用户信息以获取最新的avatar
        final profileResponse = await _dio.get('/user/profile');
        if (profileResponse.statusCode == 200) {
          await applyProfileResponse(profileResponse.data);
          return AuthResult.success();
        }
      }
      return AuthResult.failure('更新头像失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      debugPrint(
        '更新头像失败: type=${e.type}, status=${e.response?.statusCode}',
      );
      return AuthResult.failure(errorMsg);
    }
  }

  Future<AuthResult> changePassword(
    String oldPassword,
    String newPassword,
  ) async {
    try {
      final response = await _dio.post(
        '/change_password',
        data: {'old_password': oldPassword, 'new_password': newPassword},
      );
      if (response.statusCode == 200) {
        final data = response.data;
        if (data is! Map || data['user'] is! Map) {
          return AuthResult.failure('密码已修改，但会话刷新失败，请重新登录');
        }
        final candidate = _authSessionCandidateFromResponse(data);
        await _saveAndCommitAuthSession(candidate);
        return AuthResult.success();
      }
      return AuthResult.failure('修改密码失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      debugPrint(
        '修改密码失败: type=${e.type}, status=${e.response?.statusCode}',
      );
      return AuthResult.failure(errorMsg);
    }
  }

  Future<AuthResult> resetPasswordWithEdu(
    String studentId,
    String eduPassword,
    String newPassword,
  ) async =>
      AuthResult.failure('教务验证找回密码已关闭，请使用邮箱验证');

  /// 发送邮箱注册验证码。服务端使用统一文案，避免枚举现有账号。
  Future<AuthResult> requestEmailRegistrationCode(String email) async {
    try {
      final response = await _dio.post(
        '/register/email/code',
        data: {'email': email, 'purpose': 'register'},
      );
      if (response.statusCode == 200) {
        return AuthResult.success();
      }
      return AuthResult.failure('发送失败');
    } on DioException catch (e) {
      return AuthResult.failure(_parseDioError(e));
    }
  }

  /// 通过已验证邮箱注册账号。邮箱账号尚未完成学生认证时仅可使用邮箱登录。
  Future<AuthResult> registerWithEmail(
    String email,
    String code,
    String password, {
    String? nickname,
    required RegistrationConsents consents,
  }) async {
    _isLoading = true;
    notifyListeners();
    try {
      final response = await _dio.post(
        '/register/email',
        data: {
          'email': email,
          'code': code,
          'password': password,
          ...consents.toJson(),
          if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
        },
      );
      _isLoading = false;
      if (response.statusCode == 201) {
        final candidate = _authSessionCandidateFromResponse(response.data);
        await _saveAndCommitAuthSession(candidate, prefetchWallpaper: true);
        notifyListeners();
        return AuthResult.success();
      }
      return AuthResult.failure('注册失败，服务器返回异常');
    } on DioException catch (e) {
      _isLoading = false;
      notifyListeners();
      return AuthResult.failure(_parseDioError(e));
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      debugPrint('邮箱注册异常: ${e.runtimeType}');
      return AuthResult.failure('注册失败');
    }
  }

  /// 保留旧调用方的编译兼容性，但不再接受教务凭据或访问服务端。
  Future<AuthResult> verifyEdu(String studentId, String eduPassword) async =>
      AuthResult.failure('教务验证注册已关闭，请使用邮箱注册');

  Future<AuthResult> registerWithEdu(
    String studentId,
    String appPassword, {
    String? nickname,
    required String eduPassword,
    required RegistrationConsents consents,
  }) async =>
      AuthResult.failure('教务注册已关闭，请使用邮箱注册');

  /// 获取账号安全页私有资料，完整邮箱仅在此接口中返回。
  Future<Map<String, dynamic>?> getAccountSecurity() async {
    if (!isLoggedIn) return null;
    try {
      final response = await _dio.get('/user/account-security');
      if (response.statusCode == 200 && response.data is Map) {
        return Map<String, dynamic>.from(response.data as Map);
      }
    } on DioException catch (error) {
      debugPrint('读取账号安全信息失败: ${error.response?.statusCode}');
    }
    return null;
  }

  Future<AuthResult> requestUserEmailCode(String email) async {
    if (!isLoggedIn) return AuthResult.failure('请先登录');
    final purpose = _user?.emailBound == true ? 'change' : 'bind';
    try {
      await _dio.post(
        '/user/email/code',
        data: {'email': email, 'purpose': purpose},
      );
      return AuthResult.success();
    } on DioException catch (error) {
      return AuthResult.failure(_parseDioError(error),
          statusCode: error.response?.statusCode);
    }
  }

  /// 绑定或修改邮箱后服务端会签发新令牌，必须原子替换本地会话。
  Future<AuthResult> updateUserEmail({
    required String email,
    required String code,
    required String password,
  }) async {
    if (!isLoggedIn) return AuthResult.failure('请先登录');
    try {
      final response = await _dio.put('/user/email', data: {
        'email': email,
        'code': code,
        'password': password,
      });
      if (response.statusCode == 200) {
        final candidate = _authSessionCandidateFromResponse(response.data);
        await _saveAndCommitAuthSession(candidate);
        notifyListeners();
        return AuthResult.success();
      }
      return AuthResult.failure('更新邮箱失败');
    } on DioException catch (error) {
      return AuthResult.failure(_parseDioError(error),
          statusCode: error.response?.statusCode);
    }
  }

  Future<AuthResult> removeUserEmail(String password) async {
    if (!isLoggedIn) return AuthResult.failure('请先登录');
    try {
      final response =
          await _dio.delete('/user/email', data: {'password': password});
      if (response.statusCode == 200) {
        final candidate = _authSessionCandidateFromResponse(response.data);
        await _saveAndCommitAuthSession(candidate);
        notifyListeners();
        return AuthResult.success();
      }
      return AuthResult.failure('解除邮箱失败');
    } on DioException catch (error) {
      return AuthResult.failure(_parseDioError(error),
          statusCode: error.response?.statusCode);
    }
  }

  Future<AuthResult> requestEmailPasswordResetCode(String email) async {
    try {
      await _dio.post('/password/email/code', data: {
        'email': email,
        'purpose': 'reset_password',
      });
      return AuthResult.success();
    } on DioException catch (error) {
      return AuthResult.failure(_parseDioError(error),
          statusCode: error.response?.statusCode);
    }
  }

  Future<AuthResult> resetPasswordWithEmail({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    try {
      await _dio.post('/password/email/reset', data: {
        'email': email,
        'code': code,
        'new_password': newPassword,
      });
      return AuthResult.success();
    } on DioException catch (error) {
      return AuthResult.failure(_parseDioError(error),
          statusCode: error.response?.statusCode);
    }
  }

  /// 更新极光设备 RegistrationID 到后端
  Future<void> updateDeviceToken(String registrationId) async {
    if (!isLoggedIn || registrationId.isEmpty) return;
    try {
      await _dio.put(
        '/user/device_token',
        data: {'device_token': registrationId},
      );
    } catch (e) {
      debugPrint('更新设备Token失败: ${e.runtimeType}');
    }
  }

  /// 原子更新单活跃设备的远程推送设置。
  Future<AuthResult> updatePushSettings({
    required bool enabled,
    required String installationId,
    required String registrationId,
    required String noticeVersion,
    String? platform,
  }) async {
    if (!isLoggedIn) return AuthResult.failure('请先登录');
    try {
      await _dio.put(
        '/user/push-settings',
        data: {
          'enabled': enabled,
          'installation_id': installationId,
          'registration_id': registrationId,
          'notice_version': noticeVersion,
          'platform': platform ?? AppPlatforms.current.wireName,
        },
      );
      return AuthResult.success();
    } on DioException catch (error) {
      return AuthResult.failure(_parseDioError(error),
          statusCode: error.response?.statusCode);
    }
  }
}
