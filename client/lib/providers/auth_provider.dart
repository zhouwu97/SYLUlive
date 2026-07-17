import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:dio/dio.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../utils/app_feedback.dart';
import '../utils/app_navigator.dart';
import '../services/wallpaper_prefetch_service.dart';
import '../services/keep_alive_service.dart';
import '../services/grade_reminder_service.dart';
import '../widgets/auth_expired_overlay.dart';

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

  Future<void> writeEduPassword(String studentId, String password);

  Future<String?> readEduPassword(String studentId);

  Future<void> deleteEduPassword(String studentId);
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

  @override
  Future<void> writeEduPassword(String studentId, String password) async {
    await _setString(
      'edu_pwd_$studentId',
      password,
      '写入教务密码失败',
    );
  }

  @override
  Future<String?> readEduPassword(String studentId) async {
    return _preferences.getString('edu_pwd_$studentId');
  }

  @override
  Future<void> deleteEduPassword(String studentId) async {
    await _remove('edu_pwd_$studentId', '删除教务密码失败');
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

class _SharedPreferencesStore implements PreferenceStore {
  final SharedPreferences _preferences;

  const _SharedPreferencesStore(this._preferences);

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<bool> setString(String key, String value) {
    return _preferences.setString(key, value);
  }

  @override
  Future<bool> remove(String key) => _preferences.remove(key);
}

class _PlatformAuthCredentialStore implements AuthCredentialStore {
  static const _tokenKey = 'auth_token';
  static const _userKey = 'auth_user';

  @override
  Future<StoredAuthCredentials> read() async {
    if (kIsWeb) {
      return (await _preferenceStore()).read();
    }
    const storage = FlutterSecureStorage();
    return StoredAuthCredentials(
      token: await storage.read(key: _tokenKey),
      userJson: await storage.read(key: _userKey),
    );
  }

  @override
  Future<void> write({required String token, required String userJson}) async {
    if (kIsWeb) {
      return (await _preferenceStore()).write(
        token: token,
        userJson: userJson,
      );
    }
    const storage = FlutterSecureStorage();
    final oldToken = await storage.read(key: _tokenKey);
    final oldUserJson = await storage.read(key: _userKey);
    try {
      await storage.write(key: _tokenKey, value: token);
      await storage.write(key: _userKey, value: userJson);
    } catch (error, stackTrace) {
      await _restoreSecureValue(storage, _tokenKey, oldToken);
      await _restoreSecureValue(storage, _userKey, oldUserJson);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> clear() async {
    if (kIsWeb) {
      return (await _preferenceStore()).clear();
    }
    const storage = FlutterSecureStorage();
    await storage.delete(key: _tokenKey);
    await storage.delete(key: _userKey);
  }

  @override
  Future<void> writeEduPassword(String studentId, String password) async {
    if (kIsWeb) {
      return (await _preferenceStore()).writeEduPassword(studentId, password);
    }
    const storage = FlutterSecureStorage();
    await storage.write(key: 'edu_pwd_$studentId', value: password);
  }

  @override
  Future<String?> readEduPassword(String studentId) async {
    final key = 'edu_pwd_$studentId';
    if (kIsWeb) {
      return (await _preferenceStore()).readEduPassword(studentId);
    }
    const storage = FlutterSecureStorage();
    return storage.read(key: key);
  }

  @override
  Future<void> deleteEduPassword(String studentId) async {
    final key = 'edu_pwd_$studentId';
    if (kIsWeb) {
      return (await _preferenceStore()).deleteEduPassword(studentId);
    }
    const storage = FlutterSecureStorage();
    await storage.delete(key: key);
  }

  Future<void> _restoreSecureValue(
    FlutterSecureStorage storage,
    String key,
    String? value,
  ) async {
    if (value == null) {
      await storage.delete(key: key);
    } else {
      await storage.write(key: key, value: value);
    }
  }

  Future<PreferenceAuthCredentialStore> _preferenceStore() async {
    final preferences = await SharedPreferences.getInstance();
    return PreferenceAuthCredentialStore(
      _SharedPreferencesStore(preferences),
    );
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
  User? _user;
  String? _token;
  bool _isLoading = false;
  bool _initialized = false;
  Future<void>? _initializationFuture;
  int _sessionGeneration = 0;
  bool _applyingConsentRestriction = false;

  User? get user => _user;
  String? get token => _token;
  bool get isLoading => _isLoading;
  bool get isLoggedIn => _token != null && _user != null;
  bool get isInitialized => _initialized;
  int get sessionGeneration => _sessionGeneration;
  Dio get dio => _dio;
  PersistCookieJar? _cookieJar;

  AuthProvider(
    this._dio, {
    AuthCredentialStore? credentialStore,
    bool loadStoredAuth = true,
    VoidCallback? onAuthenticated,
  })  : _credentialStore = credentialStore ?? _PlatformAuthCredentialStore(),
        _usesPlatformCredentialStore = credentialStore == null,
        _onAuthenticated = onAuthenticated ?? WallpaperPrefetchService.start {
    // 添加 401 拦截器：自动登出并提示重新登录
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          _applyAuthHeader();
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

          if (status == 401 && _token != null) {
            if (isEduApi) {
              // 教务登录态失效，不代表 App 登录失效
              handler.next(error);
              return;
            }

            // 无效令牌，自动登出
            debugPrint('检测到 App 401，自动登出');
            // 统一走 _clearLocalSession，与手动退出相同路径
            // 不 await — 拦截器内部不能阻塞
            _clearLocalSession(clearPushAlias: true);
            // 重置 overlay 标记，允许再次弹出
            AuthExpiredManager.resetSessionFlag();
            // 延迟一帧弹出重新登录提示
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _showAuthExpiredOverlay();
            });
          }
          if (status == 403 &&
              (errorCode == 'legal_consent_withdrawn' ||
                  errorCode == 'legal_consent_required') &&
              _token != null) {
            // 服务端状态优先，旧的本地会话会立即切换到对应的授权门禁。
            _applyLegalConsentRestriction(
              required: errorCode == 'legal_consent_required',
            );
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
      _dio.interceptors.add(CookieManager(_cookieJar!));
    }
  }

  Future<void> _loadStoredAuth() async {
    try {
      if (_usesPlatformCredentialStore) await _initCookieJar();
      final stored = await _credentialStore.read();
      if (stored.token != null && stored.userJson != null) {
        final decoded = jsonDecode(stored.userJson!);
        if (decoded is! Map) {
          throw const FormatException('本地用户信息不是对象');
        }
        final candidate = _authSessionCandidate(
          stored.token,
          Map<String, dynamic>.from(decoded),
        );
        _commitAuthSession(candidate);
        if (candidate.user.legalConsentsActive) {
          _onAuthenticated();
        } else {
          await _clearConsentDependentLocalData(candidate.user);
        }
      }
    } catch (e) {
      debugPrint('解析本地认证信息失败: $e');
    }
    _initialized = true;
    await KeepAliveService.instance.syncAuthToken(_token);
    await GradeReminderService.instance.syncRuntimeConfig(
      userId: _user?.id.toString(),
    );
    await GradeReminderService.instance.ensureScheduledIfEnabled();
    notifyListeners();
  }

  Future<void> _saveAuthCandidate(_AuthSessionCandidate candidate) async {
    await _credentialStore.write(
      token: candidate.token,
      userJson: jsonEncode(candidate.user.toJson()),
    );
    if (candidate.user.legalConsentsActive) {
      await KeepAliveService.instance.syncAuthToken(candidate.token);
      await GradeReminderService.instance.syncRuntimeConfig(
        userId: candidate.user.id.toString(),
      );
      await GradeReminderService.instance.ensureScheduledIfEnabled();
    }
  }

  Future<void> _saveEduPassword(String studentId, String password) async {
    await _credentialStore.writeEduPassword(studentId, password);
  }

  Future<void> _saveAndCommitEduAuthSession(
    _AuthSessionCandidate candidate, {
    required String studentId,
    required String eduPassword,
  }) async {
    if (!candidate.user.legalConsentsActive) {
      await _saveAuthCandidate(candidate);
      _commitAuthSession(candidate);
      await _clearConsentDependentLocalData(candidate.user);
      return;
    }
    final oldEduPassword = await _credentialStore.readEduPassword(studentId);
    await _saveEduPassword(studentId, eduPassword);
    try {
      await _saveAuthCandidate(candidate);
    } catch (error, stackTrace) {
      if (oldEduPassword == null) {
        await _credentialStore.deleteEduPassword(studentId);
      } else {
        await _saveEduPassword(studentId, oldEduPassword);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    _commitAuthSession(candidate);
  }

  _AuthSessionCandidate _authSessionCandidate(
    Object? rawToken,
    Map<String, dynamic> userJson,
  ) {
    if (rawToken is! String || rawToken.trim().isEmpty) {
      throw const FormatException('认证令牌无效');
    }
    return _AuthSessionCandidate(rawToken, User.fromJson(userJson));
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
    _token = candidate.token;
    _user = candidate.user;
    _sessionGeneration++;
    _applyAuthHeader();
  }

  Future<void> _saveAndCommitAuthSession(
    _AuthSessionCandidate candidate, {
    bool prefetchWallpaper = false,
  }) async {
    await _saveAuthCandidate(candidate);
    _commitAuthSession(candidate);
    if (!candidate.user.legalConsentsActive) {
      await _clearConsentDependentLocalData(candidate.user);
    } else if (prefetchWallpaper) {
      _onAuthenticated();
    }
  }

  /// 解析Dio异常并返回友好的错误信息（附带技术细节方便排查）
  String _parseDioError(DioException e) {
    debugPrint('Dio error: ${e.requestOptions.uri} ${e.type} ${e.error}');
    return AppFeedback.dioErrorMessage(e, fallback: '操作失败，请稍后再试');
  }

  String _maskStudentId(String studentId) {
    final value = studentId.trim();
    if (value.length <= 4) return '****';
    return '${value.substring(0, 2)}****${value.substring(value.length - 2)}';
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
      debugPrint('注册失败: $errorMsg');
      return AuthResult.failure(errorMsg);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      debugPrint('注册失败: $e');
      return AuthResult.failure('注册失败: $e');
    }
  }

  Future<AuthResult> login(String studentId, String password) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await _dio.post(
        '/login',
        data: {'student_id': studentId, 'password': password},
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
      debugPrint('登录失败: $errorMsg');
      return AuthResult.failure(errorMsg, statusCode: e.response?.statusCode);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      debugPrint('登录失败: $e');
      return AuthResult.failure('登录失败: $e');
    }
  }

  Future<void> logout() async {
    try {
      await _dio.post('/logout'); // 调用服务端登出接口
    } catch (e) {
      debugPrint('服务端登出异常: $e');
    }
    await _clearLocalSession(clearPushAlias: true);
  }

  Future<AuthResult> deleteAccount(String password) async {
    final studentId = _user?.studentId;
    if (!isLoggedIn || studentId == null || studentId.isEmpty) {
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
      await _credentialStore.deleteEduPassword(studentId);
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

  /// 立即撤销全部法律文件授权，并保留当前会话用于查阅本人数据。
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

  Future<void> _applyLegalConsentRestriction({required bool required}) async {
    if (_applyingConsentRestriction || _user == null || _token == null) return;
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
        ..['edu_student_id'] = ''
        ..['edu_bound'] = false
        ..['edu_grade'] = ''
        ..['edu_college'] = ''
        ..['edu_major'] = '';
      final nextUser = User.fromJson(userJson);
      await _credentialStore.write(
        token: _token!,
        userJson: jsonEncode(nextUser.toJson()),
      );
      _user = nextUser;
      _sessionGeneration++;
      await _clearConsentDependentLocalData(nextUser);
      notifyListeners();
    } catch (e) {
      debugPrint('同步授权受限状态失败: $e');
    } finally {
      _applyingConsentRestriction = false;
    }
  }

  Future<void> _clearConsentDependentLocalData(User user) async {
    await _credentialStore.deleteEduPassword(user.studentId);
    if (user.eduStudentId.isNotEmpty && user.eduStudentId != user.studentId) {
      await _credentialStore.deleteEduPassword(user.eduStudentId);
    }
    await KeepAliveService.instance.syncAuthToken(null);
    await GradeReminderService.instance.clearForUser(user.id.toString());
    await GradeReminderService.instance.syncRuntimeConfig(userId: null);
    await _clearPushAlias();
  }

  /// 统一的本地会话清理
  ///
  /// [clearPushAlias] 为 true 时同时清除极光 Alias（手动退出 / 401）。
  Future<void> _clearLocalSession({required bool clearPushAlias}) async {
    final hadSession = _token != null || _user != null;
    final oldUserId = _user?.id.toString();
    if (oldUserId != null) {
      await GradeReminderService.instance.clearForUser(oldUserId);
    }
    if (!kIsWeb && _cookieJar != null) {
      await _cookieJar!.deleteAll();
    }
    await _clearStoredAuth();
    if (clearPushAlias) {
      await _clearPushAlias();
    }
    _token = null;
    _user = null;
    if (hadSession) _sessionGeneration++;
    _applyAuthHeader();
    notifyListeners();
  }

  /// 清除极光推送 Alias，防止退出后仍收到前用户私信通知
  Future<void> _clearPushAlias() async {
    try {
      await const MethodChannel('shenliyuan/private_message_notifications')
          .invokeMethod('clearAlias');
    } catch (e) {
      debugPrint('清除 JPush Alias 失败: $e');
    }
  }

  Future<void> _clearStoredAuth() async {
    await _credentialStore.clear();
    await KeepAliveService.instance.syncAuthToken(null);
    await GradeReminderService.instance.syncRuntimeConfig(userId: null);
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
      debugPrint('更新资料失败: $errorMsg');
      return AuthResult.failure(errorMsg);
    }
  }

  int _profileGeneration = 0;
  Future<void> _profileWriteTail = Future.value();

  /// 从服务器刷新当前用户信息（角色变更后调用）
  Future<void> refreshUser() async {
    if (_token == null) return;
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
      debugPrint('刷新用户信息失败: ${e.message}');
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
    final candidate = _AuthSessionCandidate(token, nextUser);

    // 先完成持久化，成功后再更新内存
    await _saveAndCommitAuthSession(candidate, prefetchWallpaper: false);
    notifyListeners();
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
      debugPrint('更新头像失败: $errorMsg');
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
        return AuthResult.success();
      }
      return AuthResult.failure('修改密码失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      debugPrint('修改密码失败: $errorMsg');
      return AuthResult.failure(errorMsg);
    }
  }

  Future<AuthResult> resetPasswordWithEdu(
    String studentId,
    String eduPassword,
    String newPassword,
  ) async {
    try {
      final response = await _dio.post(
        '/forgot_password',
        data: {
          'student_id': studentId,
          'edu_password': eduPassword,
          'new_password': newPassword,
        },
      );
      if (response.statusCode == 200) {
        return AuthResult.success();
      }
      return AuthResult.failure('密码重置失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      debugPrint('密码重置失败: $errorMsg');
      return AuthResult.failure(errorMsg);
    } catch (e) {
      debugPrint('密码重置失败: $e');
      return AuthResult.failure('密码重置失败: $e');
    }
  }

  /// 发送验证码到 QQ 邮箱
  Future<AuthResult> sendVerifyCode(String qq) async {
    try {
      final response = await _dio.post('/send_code', data: {'qq': qq});
      if (response.statusCode == 200 && response.data['success'] == true) {
        return AuthResult.success();
      }
      return AuthResult.failure(response.data['error'] ?? '发送失败');
    } on DioException catch (e) {
      return AuthResult.failure(_parseDioError(e));
    }
  }

  /// 校验验证码
  Future<AuthResult> verifyCode(String qq, String code) async {
    try {
      final response = await _dio.post(
        '/verify_code',
        data: {'qq': qq, 'code': code},
      );
      if (response.statusCode == 200 && response.data['success'] == true) {
        return AuthResult.success();
      }
      return AuthResult.failure(response.data['error'] ?? '验证失败');
    } on DioException catch (e) {
      return AuthResult.failure(_parseDioError(e));
    }
  }

  /// 验证教务账号（注册前验证学号是否属于自己）
  Future<AuthResult> verifyEdu(String studentId, String eduPassword) async {
    try {
      debugPrint('=== verifyEdu 开始 ===');
      debugPrint('student_id: ${_maskStudentId(studentId)}');

      final response = await _dio.post(
        '/edu/pre_verify',
        data: {'student_id': studentId, 'password': eduPassword},
      );

      debugPrint('=== verifyEdu 响应 ===');
      debugPrint('statusCode: ${response.statusCode}');
      debugPrint('data type: ${response.data.runtimeType}');
      if (response.data is Map) {
        debugPrint(
          'success: ${response.data['success']} code: ${response.data['code']}',
        );
      }

      if (response.statusCode == 200 && response.data['success'] == true) {
        return AuthResult.success();
      }
      return AuthResult.failure(
        response.data['error'] ?? response.data['message'] ?? '教务验证失败',
      );
    } on DioException catch (e) {
      debugPrint('=== verifyEdu DioException ===');
      debugPrint('type: ${e.type}');
      debugPrint('message: ${e.message}');
      debugPrint('response: ${e.response}');
      debugPrint('response.statusCode: ${e.response?.statusCode}');
      if (e.response?.data is Map) {
        final data = e.response?.data as Map;
        debugPrint('response.code: ${data['code']}');
      }
      debugPrint('requestOptions.uri: ${e.requestOptions.uri}');
      return AuthResult.failure(_parseDioError(e));
    } catch (e, st) {
      debugPrint('=== verifyEdu 未知异常 ===');
      debugPrint('error: $e');
      debugPrint('stackTrace: $st');
      return AuthResult.failure('未知错误: $e');
    }
  }

  Future<AuthResult> loginEdu(
    String studentId,
    String eduPassword,
    String appPassword,
  ) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await _dio.post(
        '/login_edu',
        data: {
          'student_id': studentId,
          'edu_password': eduPassword,
          'password': appPassword,
        },
      );

      _isLoading = false;
      if (response.statusCode == 200) {
        final candidate = _authSessionCandidateFromResponse(response.data);
        await _saveAndCommitEduAuthSession(
          candidate,
          studentId: studentId,
          eduPassword: eduPassword,
        );
        notifyListeners();
        return AuthResult.success();
      }
      return AuthResult.failure('登录失败，服务器返回异常');
    } on DioException catch (e) {
      _isLoading = false;
      notifyListeners();
      final errorMsg = _parseDioError(e);
      debugPrint('登录失败: $errorMsg');
      return AuthResult.failure(errorMsg);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      debugPrint('登录失败: $e');
      return AuthResult.failure('登录失败: $e');
    }
  }

  /// 教务验证后注册
  Future<AuthResult> registerWithEdu(
    String studentId,
    String appPassword, {
    String? nickname,
    required String eduPassword,
    required RegistrationConsents consents,
  }) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await _dio.post(
        '/register_with_edu',
        data: {
          'student_id': studentId,
          'password': appPassword,
          'edu_password': eduPassword,
          ...consents.toJson(),
          if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
        },
      );

      _isLoading = false;
      if (response.statusCode == 201) {
        final candidate = _authSessionCandidateFromResponse(response.data);
        await _saveAndCommitEduAuthSession(
          candidate,
          studentId: studentId,
          eduPassword: eduPassword,
        );
        notifyListeners();
        return AuthResult.success();
      }
      return AuthResult.failure('注册失败，服务器返回异常');
    } on DioException catch (e) {
      _isLoading = false;
      notifyListeners();
      final errorMsg = _parseDioError(e);
      debugPrint('注册失败: $errorMsg');
      return AuthResult.failure(errorMsg);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      debugPrint('注册失败: $e');
      return AuthResult.failure('注册失败: $e');
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
      debugPrint('更新设备Token失败: $e');
    }
  }

  Future<AuthResult> registerGraduate(
    String qq,
    String code,
    String password, {
    String? nickname,
    required RegistrationConsents consents,
  }) async {
    _isLoading = true;
    notifyListeners();
    try {
      final response = await _dio.post(
        '/register',
        data: {
          'qq': qq,
          'code': code,
          'password': password,
          ...consents.toJson(),
          if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
        },
      );

      _isLoading = false;
      if (response.statusCode == 201) {
        final candidate = _authSessionCandidateFromResponse(response.data);
        await _saveAndCommitAuthSession(candidate);
        notifyListeners();
        return AuthResult.success();
      }
      return AuthResult.failure('注册失败，服务器返回异常');
    } on DioException catch (e) {
      _isLoading = false;
      notifyListeners();
      final errorMsg = _parseDioError(e);
      debugPrint('毕业用户注册失败: $errorMsg');
      return AuthResult.failure(errorMsg);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      debugPrint('毕业用户注册失败: $e');
      return AuthResult.failure('注册失败: $e');
    }
  }
}
