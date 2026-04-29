import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';

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
    _loadStoredAuth();
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

  /// 解析Dio异常并返回友好的错误信息
  String _parseDioError(DioException e) {
    if (e.response != null) {
      final data = e.response!.data;
      // 尝试从响应体中获取error字段
      if (data is Map) {
        if (data.containsKey('error')) {
          return data['error'].toString();
        }
        if (data.containsKey('message')) {
          return data['message'].toString();
        }
      }
      // 根据状态码返回通用信息
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
    // 网络错误
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '连接超时，请检查网络';
    }
    if (e.type == DioExceptionType.connectionError) {
      return '网络连接失败，请检查网络';
    }
    return '网络错误: ${e.message}';
  }

  Future<AuthResult> register(String studentId, String password) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await _dio.post('/register', data: {
        'student_id': studentId,
        'password': password,
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
      final formData = FormData.fromMap({
        'avatar': await MultipartFile.fromFile(avatarPath),
      });
      final response = await _dio.post('/user/avatar', data: formData);
      if (response.statusCode == 200) {
        _user = User.fromJson(response.data);
        await _saveAuth();
        notifyListeners();
        return AuthResult.success();
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
}