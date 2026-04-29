import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';

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

  Future<bool> register(String studentId, String password) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await _dio.post('/register', data: {
        'student_id': studentId,
        'password': password,
      });

      if (response.statusCode == 201) {
        _token = response.data['token'];
        _user = User.fromJson(response.data['user']);
        _dio.options.headers['Authorization'] = 'Bearer $_token';
        await _saveAuth();
        _isLoading = false;
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('注册失败: $e');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> login(String studentId, String password) async {
    _isLoading = true;
    notifyListeners();

    try {
      final response = await _dio.post('/login', data: {
        'student_id': studentId,
        'password': password,
      });

      if (response.statusCode == 200) {
        _token = response.data['token'];
        _user = User.fromJson(response.data['user']);
        _dio.options.headers['Authorization'] = 'Bearer $_token';
        await _saveAuth();
        _isLoading = false;
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('登录失败: $e');
    }

    _isLoading = false;
    notifyListeners();
    return false;
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

  Future<bool> updateProfile(String nickname) async {
    try {
      final response = await _dio.put('/user/profile', data: {'nickname': nickname});
      if (response.statusCode == 200) {
        _user = User.fromJson(response.data);
        await _saveAuth();
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('更新资料失败: $e');
    }
    return false;
  }

  Future<bool> updateAvatar(String avatarPath) async {
    try {
      final formData = FormData.fromMap({
        'avatar': await MultipartFile.fromFile(avatarPath),
      });
      final response = await _dio.post('/user/avatar', data: formData);
      if (response.statusCode == 200) {
        _user = User.fromJson(response.data);
        await _saveAuth();
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('更新头像失败: $e');
    }
    return false;
  }

  Future<bool> changePassword(String oldPassword, String newPassword) async {
    try {
      final response = await _dio.post('/change_password', data: {
        'old_password': oldPassword,
        'new_password': newPassword,
      });
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('修改密码失败: $e');
      return false;
    }
  }
}