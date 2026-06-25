import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import '../config/api_constants.dart';
import '../utils/app_feedback.dart';
import '../models/edu_grade.dart';

/// 操作结果，包含成功状态和错误信息
class OperationResult<T> {
  final bool success;
  final T? data;
  final String? errorMessage;

  const OperationResult({required this.success, this.data, this.errorMessage});

  factory OperationResult.ok(T data) =>
      OperationResult(success: true, data: data);

  factory OperationResult.fail(String message) =>
      OperationResult(success: false, errorMessage: message);
}

/// 成绩缓存条目
class GradeCacheEntry {
  final List<EduGrade> grades;
  final DateTime updatedAt;

  const GradeCacheEntry({required this.grades, required this.updatedAt});
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
  bool _statusLoaded = false;
  String? _errorMessage;
  final Map<String, GradeCacheEntry> _gradeCache = {};

  bool get isBound => _isBound;
  String get studentId => _studentId;
  String get name => _name;
  String get grade => _grade;
  String get college => _college;
  String get major => _major;
  bool get isLoading => _isLoading;
  bool get isStatusLoaded => _statusLoaded;
  String? get errorMessage => _errorMessage;
  int get enrollmentYear {
    int startYear = DateTime.now().year - 4; // 默认往前推4年
    if (_studentId.length >= 2) {
      final parsed = int.tryParse(_studentId.substring(0, 2));
      if (parsed != null && parsed > 0 && parsed < 99) {
        startYear = 2000 + parsed;
      }
    }
    return startYear;
  }

  /// 内存缓存 key：edu_grades_${userId}_${year}_${semester}
  String _cacheKey(String year, int semester) {
    return 'edu_grades_${_userId}_${year}_$semester';
  }

  /// 读取内存缓存
  GradeCacheEntry? getCachedGrades(String year, int semester) {
    return _gradeCache[_cacheKey(year, semester)];
  }

  /// 清除指定用户的所有成绩缓存
  void clearGradeCacheForUser(String userId) {
    final prefix = 'edu_grades_${userId}_';
    _gradeCache.removeWhere((key, _) => key.startsWith(prefix));
  }

  /// 删除教务密码（解绑后）
  Future<void> _deleteEduPassword(String studentId) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('edu_pwd_$studentId');
    } else {
      const storage = FlutterSecureStorage();
      await storage.delete(key: 'edu_pwd_$studentId');
    }
  }

  EduProvider(Dio authDio) {
    _authDio = authDio;
    _eduDio = Dio(
      BaseOptions(
        baseUrl: ApiConstants.eduServiceUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
  }

  void setUserId(String userId) {
    if (_userId == userId) return;
    // 立即清除旧用户的所有可见状态，避免短暂显示上一位用户信息
    if (_userId != null) {
      clearGradeCacheForUser(_userId!);
    }
    _userId = userId;
    _isBound = false;
    _studentId = '';
    _name = '';
    _grade = '';
    _college = '';
    _major = '';
    _errorMessage = null;
    _statusLoaded = false;
    notifyListeners();
    // 再异步加载新用户状态
    loadStatus();
  }

  String? get userId => _userId;

  /// 解析Dio异常并返回友好的错误信息
  String _parseDioError(DioException e) {
    debugPrint('Edu Dio error: ${e.requestOptions.uri} ${e.type} ${e.error}');
    return AppFeedback.dioErrorMessage(
      e,
      serviceName: '教务服务',
      fallback: '教务操作失败，请稍后再试',
    );
  }

  // 获取绑定状态
  Future<void> loadStatus() async {
    if (_userId == null) return;

    // 极速上屏：先从本地缓存读取状态
    final cached = await _loadBoundStatus();
    if (!_statusLoaded) {
      _isBound = cached;
      _statusLoaded = true;
      notifyListeners();
    }

    try {
      final response = await _authDio.get('/edu/status');

      if (response.statusCode == 200) {
        final data = response.data;
        _isBound = data['edu_bound'] ?? false;
        _studentId = data['edu_student_id'] ?? '';
        _name = data['name'] ?? '';
        _grade = data['edu_grade'] ?? '';
        _college = data['edu_college'] ?? '';
        _major = data['edu_major'] ?? '';
        _errorMessage = null;
        _statusLoaded = true;
        await _saveBoundStatus();
        notifyListeners();
      }
    } on DioException catch (e) {
      _isBound = cached;
      _errorMessage = _parseDioError(e);
      _statusLoaded = true;
      debugPrint('获取教务状态失败: $_errorMessage，使用缓存: $cached');
      notifyListeners();
    }
  }

  Future<void> _saveBoundStatus() async {
    if (_userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('edu_bound_$_userId', _isBound);
    await prefs.setString('edu_student_id_$_userId', _studentId);
    await prefs.setString('edu_grade_$_userId', _grade);
    await prefs.setString('edu_college_$_userId', _college);
    await prefs.setString('edu_major_$_userId', _major);
  }

  Future<bool> _loadBoundStatus() async {
    if (_userId == null) return false;
    final prefs = await SharedPreferences.getInstance();
    _studentId = prefs.getString('edu_student_id_$_userId') ?? '';
    _grade = prefs.getString('edu_grade_$_userId') ?? '';
    _college = prefs.getString('edu_college_$_userId') ?? '';
    _major = prefs.getString('edu_major_$_userId') ?? '';
    return prefs.getBool('edu_bound_$_userId') ?? false;
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

  Future<String?> _loadEduPassword(String studentId) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('edu_pwd_$studentId');
    } else {
      const storage = FlutterSecureStorage();
      return await storage.read(key: 'edu_pwd_$studentId');
    }
  }

  // 绑定教务账号
  Future<bool> bind(
    String studentId,
    String password, {
    bool isSilent = false,
  }) async {
    if (_userId == null) {
      if (!isSilent) {
        _errorMessage = '用户未登录';
        notifyListeners();
      }
      return false;
    }

    if (!isSilent) {
      _isLoading = true;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      final response = await _eduDio.post(
        '/api/edu/bind',
        data: {
          'user_id': _userId,
          'student_id': studentId,
          'password': password,
        },
      );

      if (!isSilent) {
        _isLoading = false;
      }
      if (response.statusCode == 200) {
        final data = response.data;
        _isBound = true;
        _studentId = data['student_id'] ?? studentId;
        _name = data['name'] ?? '';
        _grade = data['grade'] ?? '';
        _college = data['college'] ?? '';
        _major = data['major'] ?? '';
        _errorMessage = null;
        _statusLoaded = true;
        await _saveBoundStatus();
        await _saveEduPassword(_studentId, password);
        notifyListeners();
        return true;
      }
    } on DioException catch (e) {
      if (!isSilent) {
        _isLoading = false;
        _errorMessage = _parseDioError(e);
        notifyListeners();
      }
      debugPrint('绑定教务失败: $_errorMessage');
      return false;
    }
    if (!isSilent) {
      _isLoading = false;
      _errorMessage = '绑定失败，未知错误';
      notifyListeners();
    }
    return false;
  }

  // 解绑教务账号
  Future<OperationResult<void>> unbind() async {
    if (_userId == null) {
      return OperationResult.fail('用户未登录');
    }

    final currentUserId = _userId!;
    final currentStudentId = _studentId; // 先保存，字段之后会被清空

    try {
      final response = await _eduDio.delete(
        '/api/edu/bind',
        queryParameters: {'user_id': _userId},
      );

      if (response.statusCode == 200) {
        // 清除本地状态
        _isBound = false;
        _studentId = '';
        _name = '';
        _grade = '';
        _college = '';
        _major = '';
        _errorMessage = null;
        _statusLoaded = true;

        // 清除 SharedPreferences 中该用户的教务信息
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('edu_bound_$currentUserId', false);
        await prefs.remove('edu_student_id_$currentUserId');
        await prefs.remove('edu_grade_$currentUserId');
        await prefs.remove('edu_college_$currentUserId');
        await prefs.remove('edu_major_$currentUserId');
        await prefs.remove('edu_last_semester_$currentUserId');

        // 删除安全存储中的密码
        if (currentStudentId.isNotEmpty) {
          await _deleteEduPassword(currentStudentId);
        }

        // 清除该用户的所有成绩缓存
        clearGradeCacheForUser(currentUserId);

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

  // 尝试后台静默恢复教务登录
  Future<bool> _trySilentRelogin() async {
    final pwd = await _loadEduPassword(_studentId);
    if (pwd != null && pwd.isNotEmpty) {
      debugPrint('后台尝试静默恢复教务登录...');
      AppFeedback.showGlobalToast('检测到教务登录已过期，自动为您重新登录中...');
      return await bind(_studentId, pwd, isSilent: true);
    }
    return false;
  }

  // 获取课表
  Future<OperationResult<List<Map<String, dynamic>>>?> getCourses(
    String year,
    int semester,
  ) async {
    if (_userId == null) {
      return OperationResult.fail('用户未登录');
    }

    try {
      // 调用 Go 服务器，由 Go 使用存储的 cookie 访问教务系统
      final response = await _authDio.post(
        '/edu/courses',
        data: {'year': year, 'semester': semester},
      );

      if (response.statusCode == 200) {
        final data = response.data;
        if (data['courses'] != null && (data['courses'] as List).isNotEmpty) {
          return OperationResult.ok(
            List<Map<String, dynamic>>.from(data['courses']),
          );
        }
        final errorMsg =
            (data['error'] ?? data['message'] ?? data['detail'] ?? '')
                .toString();
        if (errorMsg.isNotEmpty) {
          return OperationResult.fail(errorMsg);
        }
        if (data['success'] == false) {
          return OperationResult.fail(data['message'] ?? '获取课表失败');
        }
      }
      return OperationResult.fail('获取课表失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      if (errorMsg.contains('未登录') ||
          errorMsg.contains('过期') ||
          errorMsg.contains('重新登录') ||
          errorMsg.contains('会话') ||
          errorMsg.contains('cookie') ||
          errorMsg.contains('暂未开放') ||
          errorMsg.contains('失效') ||
          errorMsg.contains('Cookie')) {
        final rebindSuccess = await _trySilentRelogin();
        if (rebindSuccess) {
          try {
            final retryResp = await _authDio.post(
              '/edu/courses',
              data: {'year': year, 'semester': semester},
            );
            if (retryResp.statusCode == 200 &&
                retryResp.data['courses'] != null &&
                (retryResp.data['courses'] as List).isNotEmpty) {
              return OperationResult.ok(
                List<Map<String, dynamic>>.from(retryResp.data['courses']),
              );
            }
          } catch (_) {}
        } else {
          return OperationResult.fail('教务登录状态已失效，请重新绑定');
        }
      }
      debugPrint('获取课表失败: $errorMsg');
      return OperationResult.fail(errorMsg);
    }
  }

  /// 获取成绩 — 始终请求网络，返回已解析的 [EduGrade] 列表。
  /// 成功时自动写入内存缓存并记录更新时间。
  Future<OperationResult<List<EduGrade>>> fetchGrades(
    String year,
    int semester,
  ) async {
    final raw = await _fetchGradesRaw(year, semester);
    if (raw != null && raw.success && raw.data != null) {
      final grades = raw.data!.map((m) => EduGrade.fromJson(m)).toList();
      _gradeCache[_cacheKey(year, semester)] = GradeCacheEntry(
        grades: grades,
        updatedAt: DateTime.now(),
      );
      return OperationResult.ok(grades);
    }
    return OperationResult.fail(raw?.errorMessage ?? '获取成绩失败');
  }

  // 获取成绩（原始数据，内部使用）
  Future<OperationResult<List<Map<String, dynamic>>>?> _fetchGradesRaw(
    String year,
    int semester,
  ) async {
    if (_userId == null) {
      return OperationResult.fail('用户未登录');
    }

    try {
      // 调用 Go 服务器，由 Go 使用存储的 cookie 访问教务系统
      final response = await _authDio.post(
        '/edu/grades',
        data: {'year': year, 'semester': semester},
      );

      if (response.statusCode == 200) {
        final data = response.data;
        if (data['grades'] != null) {
          return OperationResult.ok(
            List<Map<String, dynamic>>.from(data['grades']),
          );
        }
        if (data['error'] != null) {
          return OperationResult.fail(data['error'].toString());
        }
      }
      return OperationResult.fail('获取成绩失败');
    } on DioException catch (e) {
      final errorMsg = _parseDioError(e);
      if (errorMsg.contains('未登录') ||
          errorMsg.contains('过期') ||
          errorMsg.contains('重新登录') ||
          errorMsg.contains('会话') ||
          errorMsg.contains('cookie') ||
          errorMsg.contains('暂未开放') ||
          errorMsg.contains('失效') ||
          errorMsg.contains('Cookie')) {
        final rebindSuccess = await _trySilentRelogin();
        if (rebindSuccess) {
          try {
            final retryResp = await _authDio.post(
              '/edu/grades',
              data: {'year': year, 'semester': semester},
            );
            if (retryResp.statusCode == 200 &&
                retryResp.data['grades'] != null) {
              return OperationResult.ok(
                List<Map<String, dynamic>>.from(retryResp.data['grades']),
              );
            }
          } catch (_) {}
        } else {
          return OperationResult.fail('教务登录状态已失效，请重新绑定');
        }
      }
      debugPrint('获取成绩失败: $errorMsg');
      return OperationResult.fail(errorMsg);
    }
  }

  /// 将课表同步到本地数据库（供课表页展示）
  /// [courses] 为 fetch 返回的原始课程列表
  Future<bool> syncCourses(
    String year,
    int semester,
    List<Map<String, dynamic>> courses,
  ) async {
    if (_userId == null) return false;

    final kbList = courses.map((c) {
      final time = c['time'] as int? ?? 1;
      return {
        'kcmc': c['name'] ?? '',
        'xm': c['teacher'] ?? '',
        'cdmc': c['location'] ?? '',
        'jc':
            '${time.toString().padLeft(2, '0')}${(time + 1).toString().padLeft(2, '0')}',
        'xqj': (c['week_day'] as int? ?? 1).toString(),
        'zcd': (c['weeks'] as List?)?.join(',') ?? '',
      };
    }).toList();

    final rawJson = jsonEncode({'kbList': kbList});

    try {
      final response = await _eduDio.post(
        '/api/edu/courses/sync',
        data: {
          'user_id': _userId,
          'year': year,
          'semester': semester,
          'raw_json': rawJson,
          'customizations': [],
        },
      );
      return response.statusCode == 200;
    } on DioException catch (e) {
      debugPrint('同步课程失败: ${_parseDioError(e)}');
      return false;
    }
  }
}
