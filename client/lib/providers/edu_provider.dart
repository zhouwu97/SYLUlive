import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../config/api_constants.dart';

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
  late final Dio _eduDio; // Python 教务服务专用
  late final Dio _authDio; // Go 服务器（获取当前用户信息）

  String? _userId;
  bool _isBound = false;
  String _studentId = '';
  String _name = '';
  String _grade = '';
  String _college = '';
  String _major = '';
  bool _isLoading = false;
  String? _errorMessage;

  bool get isBound => _isBound;
  String get studentId => _studentId;
  String get name => _name;
  String get grade => _grade;
  String get college => _college;
  String get major => _major;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  EduProvider(Dio authDio) {
    _authDio = authDio;
    _eduDio = Dio(BaseOptions(
      baseUrl: ApiConstants.eduServiceUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ));
  }

  void setUserId(String userId) {
    _userId = userId;
    loadStatus();
  }

  String? get userId => _userId;

  /// 解析Dio异常并返回友好的错误信息
  String _parseDioError(DioException e) {
    if (e.response != null) {
      final data = e.response!.data;
      // FastAPI 错误格式
      if (data is Map) {
        if (data.containsKey('detail')) {
          return data['detail'].toString();
        }
        if (data.containsKey('error')) {
          return data['error'].toString();
        }
      }
      switch (e.response!.statusCode) {
        case 401:
          return '账号或密码错误';
        case 503:
          return '教务系统不可用，请稍后重试';
        default:
          return '服务器错误 (${e.response!.statusCode})';
      }
    }

    final errType = e.type.toString();
    final cause = e.error?.toString() ?? '(无详情)';

    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '连接超时，请检查网络';
    }
    if (e.type == DioExceptionType.connectionError) {
      return '无法连接到教务服务，请确保Python服务已启动';
    }
    if (e.type == DioExceptionType.badCertificate) {
      return 'SSL证书错误';
    }
    return '网络异常[$errType]: $cause';
  }

  // 获取绑定状态
  Future<void> loadStatus() async {
    if (_userId == null) return;

    try {
      final response = await _eduDio.get(
        '/api/edu/status',
        queryParameters: {'user_id': _userId},
      );

      if (response.statusCode == 200) {
        final data = response.data;
        _isBound = data['bound'] ?? false;
        _studentId = data['student_id'] ?? '';
        _name = data['name'] ?? '';
        _grade = data['grade'] ?? '';
        _college = data['college'] ?? '';
        _major = data['major'] ?? '';
        _errorMessage = null;
        notifyListeners();
      }
    } on DioException catch (e) {
      _errorMessage = _parseDioError(e);
      debugPrint('获取教务状态失败: $_errorMessage');
      notifyListeners();
    }
  }

  // 绑定教务账号
  Future<bool> bind(String studentId, String password) async {
    if (_userId == null) {
      _errorMessage = '用户未登录';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _eduDio.post(
        '/api/edu/bind',
        data: {
          'user_id': _userId,
          'student_id': studentId,
          'password': password,
        },
      );

      _isLoading = false;
      if (response.statusCode == 200) {
        final data = response.data;
        _isBound = true;
        _studentId = data['student_id'] ?? studentId;
        _name = data['name'] ?? '';
        _grade = data['grade'] ?? '';
        _college = data['college'] ?? '';
        _major = data['major'] ?? '';
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
    if (_userId == null) {
      return OperationResult.fail('用户未登录');
    }

    try {
      final response = await _eduDio.delete(
        '/api/edu/bind',
        queryParameters: {'user_id': _userId},
      );

      if (response.statusCode == 200) {
        _isBound = false;
        _studentId = '';
        _name = '';
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
    if (_userId == null) {
      return OperationResult.fail('用户未登录');
    }

    try {
      final response = await _eduDio.post(
        '/api/edu/courses/fetch',
        data: {
          'user_id': _userId,
          'year': year,
          'semester': semester,
        },
      );

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
    if (_userId == null) {
      return OperationResult.fail('用户未登录');
    }

    try {
      final response = await _eduDio.post(
        '/api/edu/grades/',
        data: {
          'user_id': _userId,
          'year': year,
          'semester': semester,
        },
      );

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
