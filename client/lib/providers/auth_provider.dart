import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../config/api_constants.dart';

/// 认证结果，包含成功状态和错误信息
class AuthResult {
  final bool success;
  final String? errorMessage;

  const AuthResult({required this.success, this.errorMessage});

  factory AuthResult.success() => const AuthResult(success: true);

  factory AuthResult.failure(String message) => AuthResult(success: false, errorMessage: message);
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

  AuthProvider(this._dio) {
    _eduDio = Dio(BaseOptions(
      baseUrl: ApiConstants.eduServiceUrl,
      connectTimeout: ApiConstants.connectTimeout,
      receiveTimeout: ApiConstants.receiveTimeout,
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadStoredAuth());
  }

  Future<void> _loadStoredAuth() async {
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
      _dio.options.headers['Authorization'] = 'Bearer $_token';
      if (userJson != null) {
        try {
          final Map<String, dynamic> json = jsonDecode(userJson);
          _user = User.fromJson(json);
        } catch (e) {
          debugPrint('解析用户信息失败: $e');
        }
      }
    }
    _initialized = true;
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
  }

  /// 解析Dio异常并返回友好的错误信息（附带技术细节方便排查）
  String _parseDioError(DioException e) {
    final url = e.requestOptions.uri.toString();

    if (e.response != null) {
      final data = e.response!.data;
      if (data is Map) {
        if (data.containsKey('error')) {
          return data['error'].toString();
        }
        if (data.containsKey('message')) {
          return data['message'].toString();
        }
      }
      switch (e.response!.statusCode) {
        case 400:
          return '请求参数错误';
        case 401:
          return '学号/邮箱或密码错误';
        case 403:
          return '登录已过期，请重新登录';
        case 404:
          return '学号不存在，请先注册';
        case 409:
          return '学号/邮箱已存在';
        case 500:
          return '服务器错误，请稍后再试';
        default:
          return '服务器返回错误 (${e.response!.statusCode})';
      }
    }

    // 网络错误 — 附带底层异常详情
    final errType = e.type.toString();
    final cause = e.error?.toString() ?? '(无详情)';

    if (e.type == DioExceptionType.connectionTimeout) {
      return '连接超时 → $url\n$cause';
    }
    if (e.type == DioExceptionType.receiveTimeout) {
      return '接收超时 → $url\n$cause';
    }
    if (e.type == DioExceptionType.sendTimeout) {
      return '发送超时 → $url\n$cause';
    }
    if (e.type == DioExceptionType.connectionError) {
      // SocketException: No route to host / Connection refused / Network is unreachable 等
      return '无法连接到服务器 → $url\n$cause';
    }
    if (e.type == DioExceptionType.badCertificate) {
      return 'SSL证书错误 → $url\n$cause';
    }
    return '网络异常[$errType] → $url\n$cause';
  }

  Future<AuthResult> register(String studentId, String password, {String? nickname, String? qq}) async {
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
        _dio.options.headers['Authorization'] = 'Bearer $_token';
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
      final response = await _dio.post('/login', data: {
        'student_id': studentId,
        'password': password,
      });

      _isLoading = false;
      if (response.statusCode == 200) {
        _token = response.data['token'];
        _user = User.fromJson(response.data['user']);
        _dio.options.headers['Authorization'] = 'Bearer $_token';
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
      return AuthResult.failure(errorMsg);
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      debugPrint('登录失败: $e');
      return AuthResult.failure('登录失败: $e');
    }
  }

  Future<void> logout() async {
    _token = null;
    _user = null;
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey);
      await prefs.remove(_userKey);
    } else {
      const storage = FlutterSecureStorage();
      await storage.delete(key: _tokenKey);
      await storage.delete(key: _userKey);
    }
    _dio.options.headers.remove('Authorization');
    notifyListeners();
  }

  Future<AuthResult> updateProfile(String nickname) async {
    try {
      final response = await _dio.put('/user/profile', data: {'nickname': nickname});
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

  Future<AuthResult> updateAvatar(String avatarPath) async {
    try {
      // 步骤1: 上传图片文件到服务器
      final uploadFormData = FormData.fromMap({
        'file': await MultipartFile.fromFile(avatarPath),
      });
      final uploadResponse = await _dio.post('/upload', data: uploadFormData);

      if (uploadResponse.statusCode != 200 || uploadResponse.data['url'] == null) {
        return AuthResult.failure('头像上传失败');
      }

      final avatarUrl = uploadResponse.data['url'] as String;

      // 步骤2: 更新用户头像URL
      final response = await _dio.put('/user/avatar', data: {'avatar': avatarUrl});
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

  Future<AuthResult> changePassword(String oldPassword, String newPassword) async {
    try {
      final response = await _dio.post('/change_password', data: {
        'old_password': oldPassword,
        'new_password': newPassword,
      });
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
      final response = await _dio.post('/verify_code', data: {'qq': qq, 'code': code});
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

      final response = await _eduDio.post('/api/edu/pre_verify', data: {
        'student_id': studentId,
        'password': eduPassword,
      });

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
      final response = await _dio.post('/register_with_edu', data: {
        'student_id': studentId,
        'password': appPassword,
        'edu_password': eduPassword,
        if (nickname != null && nickname.isNotEmpty) 'nickname': nickname,
      });

      _isLoading = false;
      if (response.statusCode == 201) {
        _token = response.data['token'];
        _user = User.fromJson(response.data['user']);
        _dio.options.headers['Authorization'] = 'Bearer $_token';
        await _saveAuth();
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
}