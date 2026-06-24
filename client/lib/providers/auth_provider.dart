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
import '../config/api_constants.dart';
import '../utils/app_feedback.dart';
import '../utils/app_navigator.dart';
import '../services/wallpaper_prefetch_service.dart';
import '../services/keep_alive_service.dart';
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

class AuthProvider extends ChangeNotifier {
  static const String _tokenKey = 'auth_token';
  static const String _userKey = 'auth_user';

  final Dio _dio;
  late final Dio _eduDio; // Python 教务服务

  User? _user;
  String? _token;
  bool _isLoading = false;
  bool _initialized = false;

  User? get user => _user;
  String? get token => _token;
  bool get isLoading => _isLoading;
  bool get isLoggedIn => _token != null && _user != null;
  bool get isInitialized => _initialized;
  Dio get dio => _dio;
  PersistCookieJar? _cookieJar;

  AuthProvider(this._dio) {
    _eduDio = Dio(
      BaseOptions(
        baseUrl: ApiConstants.eduServiceUrl,
        connectTimeout: ApiConstants.connectTimeout,
        receiveTimeout: ApiConstants.receiveTimeout,
      ),
    );
    // 添加 401 拦截器：自动登出并提示重新登录
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          _applyAuthHeader();
          handler.next(options);
        },
        onError: (error, handler) {
          if (error.response?.statusCode == 401 && _token != null) {
            // 无效令牌，自动登出
            debugPrint('检测到 401，自动登出');
            _token = null;
            _user = null;
            _dio.options.headers.remove('Authorization');
            _clearStoredAuth();
            notifyListeners();
            // 重置 overlay 标记，允许再次弹出
            AuthExpiredManager.resetSessionFlag();
            // 延迟一帧弹出重新登录提示
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _showAuthExpiredOverlay();
            });
          }
          handler.next(error);
        },
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStoredAuth());
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
    await _initCookieJar();

    String? token;
    String? userJson;

    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      token = prefs.getString(_tokenKey);
      userJson = prefs.getString(_userKey);
    } else {
      const storage = FlutterSecureStorage();
      token = await storage.read(key: _tokenKey);
      userJson = await storage.read(key: _userKey);
    }

    if (token != null) {
      _token = token;
      _applyAuthHeader();
      if (userJson != null) {
        try {
          final Map<String, dynamic> json = jsonDecode(userJson);
          _user = User.fromJson(json);
          WallpaperPrefetchService.start();
        } catch (e) {
          debugPrint('解析用户信息失败: $e');
        }
      }
    }
    _initialized = true;
    await KeepAliveService.instance.syncAuthToken(_token);
    notifyListeners();
  }

  Future<void> _saveAuth() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      if (_token != null) {
        await prefs.setString(_tokenKey, _token!);
      }
      if (_user != null) {
        await prefs.setString(_userKey, jsonEncode(_user!.toJson()));
      }
    } else {
      const storage = FlutterSecureStorage();
      if (_token != null) {
        await storage.write(key: _tokenKey, value: _token);
      }
      if (_user != null) {
        await storage.write(key: _userKey, value: jsonEncode(_user!.toJson()));
      }
    }
    await KeepAliveService.instance.syncAuthToken(_token);
  }

  Future<void> _saveEduPassword(String studentId, String password) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('edu_pwd_$studentId', password);
    } else {
      const storage = FlutterSecureStorage();
      await storage.write(key: 'edu_pwd_$studentId', value: password);
    }
  }

  /// 解析Dio异常并返回友好的错误信息（附带技术细节方便排查）
  String _parseDioError(DioException e) {
    debugPrint('Dio error: ${e.requestOptions.uri} ${e.type} ${e.error}');
    return AppFeedback.dioErrorMessage(e, fallback: '操作失败，请稍后再试');
  }

  Future<AuthResult> register(
    String studentId,
    String password, {
    String? nickname,
    String? qq,
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
      final response = await _dio.post('/register', data: data);

      _isLoading = false;
      if (response.statusCode == 201) {
        _token = response.data['token'];
        _user = User.fromJson(response.data['user']);
        _applyAuthHeader();
        WallpaperPrefetchService.start();
        await _saveAuth();
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
        _token = response.data['token'];
        _user = User.fromJson(response.data['user']);
        _applyAuthHeader();
        WallpaperPrefetchService.start();
        await _saveAuth();
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
    _token = null;
    _user = null;
    _applyAuthHeader();
    if (!kIsWeb && _cookieJar != null) {
      await _cookieJar!.deleteAll();
    }
    await _clearStoredAuth();
    // 清除极光推送 Alias，防止退出后仍收到前用户私信通知
    try {
      await const MethodChannel('shenliyuan/private_message_notifications')
          .invokeMethod('clearAlias');
    } catch (e) {
      debugPrint('清除 JPush Alias 失败: $e');
    }
    notifyListeners();
  }

  Future<void> _clearStoredAuth() async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
      await prefs.remove(_userKey);
    } else {
      const storage = FlutterSecureStorage();
      await storage.delete(key: _tokenKey);
      await storage.delete(key: _userKey);
    }
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
        _user = User.fromJson(response.data);
        await _saveAuth();
        notifyListeners();
        return AuthResult.success();
      }
      return AuthResult.failure('更新资料失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      debugPrint('更新资料失败: $errorMsg');
      return AuthResult.failure(errorMsg);
    }
  }

  /// 从服务器刷新当前用户信息（角色变更后调用）
  Future<void> refreshUser() async {
    if (_token == null) return;
    try {
      final response = await _dio.get('/user/profile');
      if (response.statusCode == 200) {
        _user = User.fromJson(response.data);
        await _saveAuth();
        notifyListeners();
      }
    } on DioException catch (e) {
      debugPrint('刷新用户信息失败: ${e.message}');
    }
  }

  Future<void> applyAuthPayload(
    String token,
    Map<String, dynamic> userJson,
  ) async {
    _token = token;
    _user = User.fromJson(userJson);
    _applyAuthHeader();
    WallpaperPrefetchService.start();
    await _saveAuth();
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
          _user = User.fromJson(profileResponse.data);
          await _saveAuth();
          notifyListeners();
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
      // 教务服务使用专用的 eduDio，路由是 /api/edu/pre_verify
      debugPrint('=== verifyEdu 开始 ===');
      debugPrint('student_id: $studentId');
      debugPrint('baseUrl: ${_eduDio.options.baseUrl}');
      debugPrint('fullUrl: ${_eduDio.options.baseUrl}/api/edu/pre_verify');

      final response = await _eduDio.post(
        '/api/edu/pre_verify',
        data: {'student_id': studentId, 'password': eduPassword},
      );

      debugPrint('=== verifyEdu 响应 ===');
      debugPrint('statusCode: ${response.statusCode}');
      debugPrint('data: ${response.data}');
      debugPrint('data type: ${response.data.runtimeType}');

      if (response.statusCode == 200 && response.data['success'] == true) {
        return AuthResult.success();
      }
      return AuthResult.failure(response.data['error'] ?? '教务验证失败');
    } on DioException catch (e) {
      debugPrint('=== verifyEdu DioException ===');
      debugPrint('type: ${e.type}');
      debugPrint('message: ${e.message}');
      debugPrint('response: ${e.response}');
      debugPrint('response.statusCode: ${e.response?.statusCode}');
      debugPrint('response.data: ${e.response?.data}');
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
        _token = response.data['token'];
        _user = User.fromJson(response.data['user']);
        _applyAuthHeader();
        await _saveAuth();
        await _saveEduPassword(studentId, eduPassword);
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
          if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
        },
      );

      _isLoading = false;
      if (response.statusCode == 201) {
        _token = response.data['token'];
        _user = User.fromJson(response.data['user']);
        _applyAuthHeader();
        await _saveAuth();
        await _saveEduPassword(studentId, eduPassword);
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
          if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
        },
      );

      _isLoading = false;
      if (response.statusCode == 201) {
        _token = response.data['token'];
        _user = User.fromJson(response.data['user']);
        _applyAuthHeader();
        await _saveAuth();
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
