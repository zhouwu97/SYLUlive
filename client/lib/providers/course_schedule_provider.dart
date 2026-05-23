import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_constants.dart';
import '../services/home_widget_service.dart';

/// 单个课程块，用于课表网格展示
class CourseBlock {
  final int id;
  final String courseCode;
  final String name;
  final String? teacher;
  final String? location;
  final String color;
  final int weekday;
  final int startSection;
  final int endSection;
  final List<int> weeks;
  final String? note;

  const CourseBlock({
    required this.id,
    required this.courseCode,
    required this.name,
    this.teacher,
    this.location,
    required this.color,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.weeks,
    this.note,
  });

  int get span => endSection - startSection + 1;

  Map<String, dynamic> toJson() => {
        'id': id,
        'course_code': courseCode,
        'name': name,
        'teacher': teacher,
        'location': location,
        'color': color,
        'weekday': weekday,
        'start_section': startSection,
        'end_section': endSection,
        'weeks': weeks,
        'note': note,
      };

  factory CourseBlock.fromJson(Map<String, dynamic> json) {
    return CourseBlock(
      id: json['id'] ?? 0,
      courseCode: json['course_code'] ?? '',
      name: (json['custom_name'] ?? json['original_name'] ?? json['name'] ?? '')
          as String,
      teacher: json['teacher'] as String?,
      location: json['location'] as String?,
      color: json['color'] ?? '#6366F1',
      weekday: json['weekday'] ?? 1,
      startSection: json['start_section'] ?? 1,
      endSection: json['end_section'] ?? 1,
      weeks: (json['weeks'] as List<dynamic>?)?.map((e) => e as int).toList() ??
          [],
      note: json['note'] as String?,
    );
  }
}

/// 课表数据提供者 —— 只负责课程网格数据，不管理教务绑定
/// 绑定状态由 [EduProvider] 统一管理，本 Provider 只负责拉取和展示本地课程
class CourseScheduleProvider extends ChangeNotifier {
  late final Dio _eduDio;

  String? _userId;
  bool _isLoading = false;
  String? _errorMessage;

  // 当前选中的学年和学期
  String _selectedYear = '';
  int _selectedSemester = 3;

  // 课程数据
  List<CourseBlock> _courses = [];
  Map<int, Map<int, List<CourseBlock>>> _gridData = {};

  // 本地缓存 key 前缀
  static const String _cacheKeyPrefix = 'course_cache_v3_';
  static const int _cacheVersion = 3;

  // 学期起始日期（用于推算教学周）
  DateTime? _semesterStart;
  static const String _semesterStartKey = 'semester_start';

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String get selectedYear => _selectedYear;
  int get selectedSemester => _selectedSemester;
  List<CourseBlock> get courses => _courses;
  Map<int, Map<int, List<CourseBlock>>> get gridData => _gridData;
  String? get userId => _userId;
  DateTime? get semesterStart => _semesterStart;
  String? get cacheUserId => _userId;

  CourseScheduleProvider() {
    _eduDio = Dio(BaseOptions(
      baseUrl: ApiConstants.eduServiceUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 60),
    ));
    _initDefaults();
  }

  void _initDefaults() {
    final now = DateTime.now();
    int currentYear = now.year;
    
    // 如果当前是 2月到7月（春季学期），则属于上一年的秋季入学的学年，正方系统通常用 12 表示春季(第二学期)
    if (now.month >= 2 && now.month <= 7) {
      _selectedYear = (currentYear - 1).toString();
      _selectedSemester = 12; // 春季（第二学期）
    } else if (now.month == 1) {
      // 1月份还是秋季学期末，属于上一年的学年
      _selectedYear = (currentYear - 1).toString();
      _selectedSemester = 3; // 秋季（第一学期）
    } else {
      // 8月到12月，属于当前年份的秋季学期
      _selectedYear = currentYear.toString();
      _selectedSemester = 3; // 秋季（第一学期）
    }
  }

  /// 设置当前用户，但不自动拉取数据（由调用方决定何时拉取）
  void setUserId(String userId) {
    if (_userId == userId) return;
    _userId = userId;
    loadSemesterStart();
  }

  /// 默认颜色池（按课程名哈希分配）
  static const List<String> _colorPool = [
    '#6366F1',
    '#8B5CF6',
    '#EC4899',
    '#06B6D4',
    '#F59E0B',
    '#10B981',
    '#EF4444',
    '#3B82F6',
  ];

  /// 检查是否有缓存的课程（不自动拉取）
  Future<bool> hasCachedCourses() async {
    if (_userId == null) return false;
    final cacheKey = '$_cacheKeyPrefix$_userId';
    final cached = await _loadFromCache(cacheKey);
    return cached != null && cached.isNotEmpty;
  }

  Future<bool> loadCachedCoursesIfAvailable() async {
    if (_userId == null) return false;
    final cacheKey = '$_cacheKeyPrefix$_userId';
    final cached = await _loadFromCache(cacheKey);
    if (cached == null || cached.isEmpty) {
      return false;
    }
    _courses = cached;
    _buildGrid();
    _isLoading = false;
    _errorMessage = null;
    notifyListeners();
    _syncWidget(); // 更新桌面小部件
    return true;
  }

  Future<void> applyFetchedCourses(
      List<Map<String, dynamic>> rawCourses) async {
    if (_userId == null) return;

    _courses = rawCourses.map(_courseFromFetchedMap).toList();
    _buildGrid();
    _isLoading = false;
    _errorMessage = null;

    if (_courses.isNotEmpty) {
      await _saveToCache('$_cacheKeyPrefix$_userId', _courses);
    }

    notifyListeners();
    _syncWidget(); // 更新桌面小部件
  }

  CourseBlock _courseFromFetchedMap(Map<String, dynamic> map) {
    final name = map['name'] as String? ?? '';
    final time = map['time'] as int? ?? 1;
    final endTime = map['end_time'] as int? ?? (time + 1);
    return CourseBlock(
      id: 0,
      courseCode: '',
      name: name,
      teacher: map['teacher'] as String?,
      location: map['location'] as String?,
      color: _colorPool[name.hashCode.abs() % _colorPool.length],
      weekday: map['week_day'] as int? ?? 1,
      startSection: time,
      endSection: endTime,
      weeks:
          (map['weeks'] as List<dynamic>?)?.map((e) => e as int).toList() ?? [],
    );
  }

  /// 加载课程。默认先从手机缓存读取，[forceRefresh]=true 时跳过缓存从服务器拉取
  /// [onlyCache] 为 true 时，如果没有缓存则不自动拉取，直接返回
  Future<void> loadCourses(
      {bool forceRefresh = false, bool onlyCache = false}) async {
    if (_userId == null) return;

    final cacheKey = '$_cacheKeyPrefix$_userId';

    // 非强制刷新时，先尝试手机缓存
    if (!forceRefresh) {
      final cached = await _loadFromCache(cacheKey);
      if (cached != null) {
        _courses = cached;
        _buildGrid();
        debugPrint('📱 从手机缓存加载: ${_courses.length}门课');
        for (final c in _courses) {
          debugPrint(
              '  ${c.name} | 周${c.weekday} | 第${c.startSection}-${c.endSection}节');
        }
        _isLoading = false;
        notifyListeners();
        _syncWidget(); // 更新桌面小部件
        return; // 缓存命中，不请求网络
      }
    }

    // 缓存未命中且 onlyCache=true 时，不自动拉取
    if (onlyCache) {
      _courses = [];
      _gridData = {};
      _isLoading = false;
      notifyListeners();
      return;
    }

    // 缓存未命中或强制刷新 → 先清旧缓存，再请求网络
    List<CourseBlock> oldCustoms = [];
    if (forceRefresh) {
      final cached = await _loadFromCache(cacheKey);
      if (cached != null) {
        oldCustoms = cached.where((c) => c.id < 0).toList();
      }
      await clearCache();
    }
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    // Step 1: 尝试服务器本地数据（包含用户自定义颜色/名称）
    bool localSuccess = false;
    try {
      final localResp = await _eduDio.get(
        '/api/edu/courses/local',
        queryParameters: {'user_id': _userId},
      );

      if (localResp.statusCode == 200) {
        final data = localResp.data;
        final coursesJson = data['courses'] as List<dynamic>? ?? [];
        if (coursesJson.isNotEmpty) {
          _courses = coursesJson
              .map((c) => CourseBlock.fromJson(c as Map<String, dynamic>))
              .toList();
          _buildGrid();
          localSuccess = true;
          debugPrint('✅ 从服务器本地加载: ${_courses.length}门课');
          for (final c in _courses) {
            debugPrint(
                '  ${c.name} | 周${c.weekday} | 第${c.startSection}-${c.endSection}节');
          }
        }
      }
    } on DioException catch (e) {
      debugPrint('获取本地课程失败: ${_parseDioError(e)}');
    }

    // Step 2: 服务器本地为空，从教务系统拉取原始数据
    if (!localSuccess) {
      try {
        final fetchResp = await _eduDio.post(
          '/api/edu/courses/fetch',
          data: {
            'user_id': _userId,
            'year': _selectedYear,
            'semester': _selectedSemester,
          },
        );

        if (fetchResp.statusCode == 200) {
          final data = fetchResp.data;
          if (data['success'] == true) {
            final rawCourses = data['courses'] as List<dynamic>? ?? [];
            _courses = rawCourses
                .map((c) => _courseFromFetchedMap(c as Map<String, dynamic>))
                .toList();
            if (oldCustoms.isNotEmpty) {
              _courses.addAll(oldCustoms);
            }
            _buildGrid();
            debugPrint('🌐 从教务拉取原始数据: ${_courses.length}门课');
            for (final c in _courses) {
              debugPrint(
                  '  ${c.name} | 周${c.weekday} | 第${c.startSection}-${c.endSection}节 | ${c.teacher} | ${c.location}');
            }
          } else {
            _errorMessage = data['message'] as String?;
          }
        }
      } on DioException catch (e) {
        _errorMessage = _parseDioError(e);
        debugPrint('从教务拉取课程失败: $_errorMessage');
      }
    }

    // 网络请求成功后，保存到手机缓存
    if (_courses.isNotEmpty) {
      await _saveToCache(cacheKey, _courses);
    }

    _isLoading = false;
    notifyListeners();
    _syncWidget(); // 更新桌面小部件
  }

  /// 同步课程数据到桌面小部件（非阻塞）
  void _syncWidget() {
    if (_userId == null) return;
    // 使用 microtask 避免阻塞 UI
    Future.microtask(() => HomeWidgetService.syncTodayCourses(this));
  }

  /// 保存课程到 SharedPreferences
  Future<void> _saveToCache(String key, List<CourseBlock> courses) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(courses.map((c) => c.toJson()).toList());
      await prefs.setString(key, json);
      await prefs.setInt('${key}_ver', _cacheVersion);
    } catch (e) {
      debugPrint('缓存课程失败: $e');
    }
  }

  /// 从 SharedPreferences 读取缓存的课程（自动校验版本）
  Future<List<CourseBlock>?> _loadFromCache(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final version = prefs.getInt('${key}_ver') ?? 0;
      if (version < _cacheVersion) {
        // 版本不匹配，清除旧缓存
        await prefs.remove(key);
        await prefs.setInt('${key}_ver', _cacheVersion);
        return null;
      }
      final json = prefs.getString(key);
      if (json == null || json.isEmpty) return null;
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => CourseBlock.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('读取缓存课程失败: $e');
      return null;
    }
  }

  /// 清除当前用户的手机缓存
  Future<void> clearCache() async {
    if (_userId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_cacheKeyPrefix$_userId');
    } catch (e) {
      debugPrint('清除缓存失败: $e');
    }
  }

  String _parseDioError(DioException e) {
    if (e.response != null) {
      final data = e.response!.data;
      if (data is Map) {
        if (data.containsKey('detail')) return data['detail'].toString();
        if (data.containsKey('error')) return data['error'].toString();
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
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '连接超时，请检查网络';
    }
    if (e.type == DioExceptionType.connectionError) {
      return '无法连接到教务服务';
    }
    return '网络异常';
  }

  /// 将课程列表组织成网格：weekday -> section -> courses
  void _buildGrid() {
    _gridData = {};
    for (final course in _courses) {
      final wd = course.weekday;
      _gridData.putIfAbsent(wd, () => {});
      for (int s = course.startSection; s <= course.endSection; s++) {
        _gridData[wd]!.putIfAbsent(s, () => []);
        _gridData[wd]![s]!.add(course);
      }
    }
  }

  List<CourseBlock> getCoursesAt(int weekday, int section) {
    return _gridData[weekday]?[section] ?? [];
  }

  bool isCourseStart(CourseBlock course, int section) {
    return course.startSection == section;
  }

  /// 设置学期起始日期（周一），持久化到 SharedPreferences
  Future<void> setSemesterStart(DateTime date) async {
    // 对齐到周一
    _semesterStart = DateTime(date.year, date.month, date.day)
        .subtract(Duration(days: date.weekday - 1));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_semesterStartKey, _semesterStart!.toIso8601String());
    notifyListeners();
  }

  /// 从 SharedPreferences 加载学期起始日期
  Future<void> loadSemesterStart() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_semesterStartKey);
    if (s != null) {
      _semesterStart = DateTime.tryParse(s);
    }
  }

  /// 计算给定日期对应的教学周号（1-based），未设置则返回 null
  int? getAcademicWeek(DateTime date) {
    if (_semesterStart == null) return null;
    final diff = date.difference(_semesterStart!).inDays;
    if (diff < 0) return null;
    return (diff / 7).floor() + 1;
  }

  bool isCourseActive(CourseBlock course, int academicWeek) {
    return course.weeks.isEmpty || course.weeks.contains(academicWeek);
  }

  /// 添加自定义课程到本地缓存
  Future<CourseBlock> addCustomCourse({
    required String name,
    required int weekday,
    required int startSection,
    required int endSection,
    required int startWeek,
    required int endWeek,
    String? teacher,
    String? location,
  }) async {
    final weeks = List.generate(
      endWeek - startWeek + 1,
      (i) => startWeek + i,
    );
    final colorIdx = name.hashCode.abs() % _colorPool.length;
    final newId = -DateTime.now().millisecondsSinceEpoch; // 负数ID区分自定义课程

    final course = CourseBlock(
      id: newId,
      courseCode: 'custom_$newId',
      name: name,
      teacher: teacher,
      location: location,
      color: _colorPool[colorIdx],
      weekday: weekday,
      startSection: startSection,
      endSection: endSection,
      weeks: weeks,
    );

    _courses.add(course);
    _buildGrid();

    if (_userId != null) {
      await _saveToCache('$_cacheKeyPrefix$_userId', _courses);
    }

    notifyListeners();
    return course;
  }

  /// 删除自定义课程
  Future<void> removeCustomCourse(int courseId) async {
    _courses.removeWhere((c) => c.id == courseId);
    _buildGrid();
    if (_userId != null) {
      await _saveToCache('$_cacheKeyPrefix$_userId', _courses);
    }
    notifyListeners();
  }

  void setSemester(String year, int semester) {
    _selectedYear = year;
    _selectedSemester = semester;
  }
}
