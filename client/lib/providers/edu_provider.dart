import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

/// 操作结果，包含成功状态和错误信息
class OperationResult<T> {
  final bool success;
  final T? data;
  final String? errorMessage;

  const OperationResult({required this.success, this.data, this.errorMessage});

  factory OperationResult.ok(T data) => OperationResult(success: true, data: data);

  factory OperationResult.fail(String message) => OperationResult(success: false, errorMessage: message);
}

class EduProvider extends ChangeNotifier {
  final Dio _dio;

  bool _isBound = false;
  String _studentId = '';
  String _grade = '';
  String _college = '';
  String _major = '';
  bool _isLoading = false;
  String? _errorMessage;

  bool get isBound => _isBound;
  String get studentId => _studentId;
  String get grade => _grade;
  String get college => _college;
  String get major => _major;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  EduProvider(this._dio);

  /// 解析Dio异常并返回友好的错误信息
  String _parseDioError(DioException e) {
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
          return '登录已过期，请重新登录';
        case 403:
          return '无权访问教务系统';
        case 404:
          return '教务账号不存在';
        case 422:
          return '账号或密码错误';
        case 500:
          return '服务器错误，请稍后再试';
        default:
          return '服务器返回错误 (${e.response!.statusCode})';
      }
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '连接超时，请检查网络';
    }
    if (e.type == DioExceptionType.connectionError) {
      return '网络连接失败，请检查网络';
    }
    return '网络错误: ${e.message}';
  }

  // 获取绑定状态
  Future<void> loadStatus() async {
    try {
      final response = await _dio.get('/edu/status');
      if (response.statusCode == 200) {
        final data = response.data;
        _isBound = data['edu_bound'] ?? false;
        _studentId = data['edu_student_id'] ?? '';
        _grade = data['edu_grade'] ?? '';
        _college = data['edu_college'] ?? '';
        _major = data['edu_major'] ?? '';
        _errorMessage = null;
        notifyListeners();
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        _errorMessage = '请先登录';
      } else {
        _errorMessage = _parseDioError(e);
      }
      debugPrint('获取教务状态失败: $_errorMessage');
      notifyListeners();
    }
  }

  // 绑定教务账号
  Future<bool> bind(String studentId, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _dio.post('/edu/bind', data: {
        'student_id': studentId,
        'password': password,
      });

      _isLoading = false;
      if (response.statusCode == 200) {
        _isBound = true;
        _studentId = studentId;
        final data = response.data;
        _grade = data['edu_grade'] ?? '';
        _college = data['edu_college'] ?? '';
        _major = data['edu_major'] ?? '';
        _errorMessage = null;
        notifyListeners();
        return true;
      }
    } on DioException catch (e) {
      _isLoading = false;
      _errorMessage = _parseDioError(e);
      debugPrint('绑定教务失败: $_errorMessage');
      notifyListeners();
      return false;
    }
    _isLoading = false;
    _errorMessage = '绑定失败，未知错误';
    notifyListeners();
    return false;
  }

  // 解绑教务账号
  Future<OperationResult<void>> unbind() async {
    try {
      final response = await _dio.delete('/edu/bind');
      if (response.statusCode == 200) {
        _isBound = false;
        _studentId = '';
        _grade = '';
        _college = '';
        _major = '';
        notifyListeners();
        return OperationResult.ok(null);
      }
      return OperationResult.fail('解绑失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      debugPrint('解绑教务失败: $errorMsg');
      return OperationResult.fail(errorMsg);
    }
  }

  // 获取课表
  Future<OperationResult<List<Map<String, dynamic>>>?> getCourses(String year, int semester) async {
    try {
      final response = await _dio.post('/edu/courses', data: {
        'year': year,
        'semester': semester,
      });

      if (response.statusCode == 200) {
        final data = response.data;
        if (data['courses'] != null) {
          return OperationResult.ok(List<Map<String, dynamic>>.from(data['courses']));
        }
      }
      return OperationResult.fail('获取课表失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      debugPrint('获取课表失败: $errorMsg');
      return OperationResult.fail(errorMsg);
    }
  }

  // 获取成绩
  Future<OperationResult<List<Map<String, dynamic>>>?> getGrades(String year, int semester) async {
    try {
      final response = await _dio.post('/edu/grades', data: {
        'year': year,
        'semester': semester,
      });

      if (response.statusCode == 200) {
        final data = response.data;
        if (data['grades'] != null) {
          return OperationResult.ok(List<Map<String, dynamic>>.from(data['grades']));
        }
      }
      return OperationResult.fail('获取成绩失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      debugPrint('获取成绩失败: $errorMsg');
      return OperationResult.fail(errorMsg);
    }
  }
}