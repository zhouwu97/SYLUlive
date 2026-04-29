import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

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
        _errorMessage = '网络错误';
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
        notifyListeners();
        return true;
      }
    } on DioException catch (e) {
      _isLoading = false;
      if (e.response?.statusCode == 401) {
        _errorMessage = e.response?.data['error'] ?? '教务账号或密码错误';
      } else {
        _errorMessage = '绑定失败，请检查网络';
      }
      debugPrint('绑定教务失败: $_errorMessage');
      notifyListeners();
      return false;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  // 解绑教务账号
  Future<bool> unbind() async {
    try {
      final response = await _dio.delete('/edu/bind');
      if (response.statusCode == 200) {
        _isBound = false;
        _studentId = '';
        _grade = '';
        _college = '';
        _major = '';
        notifyListeners();
        return true;
      }
    } catch (e) {
      debugPrint('解绑教务失败: $e');
    }
    return false;
  }

  // 获取课表
  Future<List<Map<String, dynamic>>?> getCourses(String year, int semester) async {
    try {
      final response = await _dio.post('/edu/courses', data: {
        'year': year,
        'semester': semester,
      });

      if (response.statusCode == 200) {
        final data = response.data;
        if (data['courses'] != null) {
          return List<Map<String, dynamic>>.from(data['courses']);
        }
      }
    } catch (e) {
      debugPrint('获取课表失败: $e');
    }
    return null;
  }

  // 获取成绩
  Future<List<Map<String, dynamic>>?> getGrades(String year, int semester) async {
    try {
      final response = await _dio.post('/edu/grades', data: {
        'year': year,
        'semester': semester,
      });

      if (response.statusCode == 200) {
        final data = response.data;
        if (data['grades'] != null) {
          return List<Map<String, dynamic>>.from(data['grades']);
        }
      }
    } catch (e) {
      debugPrint('获取成绩失败: $e');
    }
    return null;
  }
}