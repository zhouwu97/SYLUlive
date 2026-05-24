import 'dart:io';
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
      id: (json['id'] as num?)?.toInt() ?? 0,
      courseCode: json['course_code']?.toString() ?? '',
      name: (json['custom_name']?.toString() ?? json['original_name']?.toString() ?? json['name']?.toString() ?? ''),
      teacher: json['teacher']?.toString(),
      location: json['location']?.toString(),
      color: json['color']?.toString() ?? '#6366F1',
      weekday: (json['weekday'] as num?)?.toInt() ?? 1,
      startSection: (json['start_section'] as num?)?.toInt() ?? 1,
      endSection: (json['end_section'] as num?)?.toInt() ?? 1,
      weeks: (json['weeks'] as List<dynamic>?)?.map((e) => (e as num).toInt()).toList() ?? [],
      note: json['note']?.toString(),
    );
  }
}

/// 课表存档
class CourseArchive {
  final String id;
  final String name;
  final DateTime createdAt;
  final int courseCount;

  const CourseArchive({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.courseCount,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'created_at': createdAt.toIso8601String(),
        'course_count': courseCount,
      };

  factory CourseArchive.fromJson(Map<String, dynamic> json) {
    return CourseArchive(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      courseCount: (json['course_count'] as num?)?.toInt() ?? 0,
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

  // 本地缓存 key
  static const String _cacheKeyPrefix = 'course_cache_v4_';
  static const int _cacheVersion = 4;

  String get _currentCacheKey => '$_cacheKeyPrefix${_userId}_${_selectedYear}_$_selectedSemester';
  String get _hiddenCoursesCacheKey => 'course_hidden_v4_${_userId}_${_selectedYear}_$_selectedSemester';
  Set<int> _hiddenCourseIds = {};

  // 存档相关
  static const String _archiveListKeyPrefix = 'course_archives_v1_';
  static const String _archiveDataKeyPrefix = 'course_archive_data_v1_';
  static const String _activeArchiveIdKeyPrefix = 'active_archive_v1_';
  List<CourseArchive> _archives = [];
  String get _archiveListKey => '$_archiveListKeyPrefix${_userId}_${_selectedYear}_$_selectedSemester';
  String get _activeArchiveKey => '$_activeArchiveIdKeyPrefix${_userId}_${_selectedYear}_$_selectedSemester';

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
  List<CourseArchive> get archives => _archives;

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
  /// 切换用户时自动清空内存中的旧数据，防止跨账号泄漏
  void setUserId(String userId) {
    if (_userId == userId) return;
    // 切换到了不同用户 → 立刻清空旧数据
    _courses = [];
    _gridData = {};
    _hiddenCourseIds = {};
    _archives = [];
    _errorMessage = null;
    _userId = userId;
    loadSemesterStart();
    loadArchiveList();
    notifyListeners();
  }

  /// 彻底清空当前用户所有内存状态（用于登出场景）
  void clearAllUserState() {
    _userId = null;
    _courses = [];
    _gridData = {};
    _hiddenCourseIds = {};
    _archives = [];
    _errorMessage = null;
    _semesterStart = null;
    _isLoading = false;
    notifyListeners();
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
    final cacheKey = _currentCacheKey;
    final cached = await _loadFromCache(cacheKey);
    return cached != null && cached.isNotEmpty;
  }

  Future<bool> loadCachedCoursesIfAvailable() async {
    if (_userId == null) return false;
    final cacheKey = _currentCacheKey;
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
      await _saveToCache(_currentCacheKey, _courses);
    }

    notifyListeners();
    _syncWidget(); // 更新桌面小部件
  }

  CourseBlock _courseFromFetchedMap(Map<String, dynamic> map) {
    final name = map['name'] as String? ?? '';
    final time = map['time'] as int? ?? 1;
    final endTime = map['end_time'] as int? ?? (time + 1);
    final weekday = map['week_day'] as int? ?? 1;
    final teacher = map['teacher'] as String? ?? '';
    final loc = map['location'] as String? ?? '';
    
    // 生成稳定的正数 ID
    final idStr = '$name-$weekday-$time-$endTime-$teacher-$loc';
    int id = idStr.hashCode.abs();
    if (id == 0) id = 1;

    return CourseBlock(
      id: id,
      courseCode: '',
      name: name,
      teacher: map['teacher'] as String?,
      location: map['location'] as String?,
      color: _colorPool[name.hashCode.abs() % _colorPool.length],
      weekday: weekday,
      startSection: time,
      endSection: endTime,
      weeks:
          (map['weeks'] as List<dynamic>?)?.map((e) => e as int).toList() ?? [],
    );
  }

  Future<void> _loadHiddenCourses() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_hiddenCoursesCacheKey);
      if (jsonStr != null) {
        final List<dynamic> list = jsonDecode(jsonStr);
        _hiddenCourseIds = list.map((e) => e as int).toSet();
      } else {
        _hiddenCourseIds = {};
      }
    } catch (e) {
      _hiddenCourseIds = {};
    }
  }

  Future<void> _saveHiddenCourses() async {
    try {
      if (_userId == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hiddenCoursesCacheKey, jsonEncode(_hiddenCourseIds.toList()));
    } catch (e) {
      debugPrint('保存隐藏课程失败: $e');
    }
  }

  /// 拉取课程。默认优先缓存。
  /// [forceRefresh] 强制拉取（用于静默同步或手动刷新）
  /// [onlyCache] 为 true 时，如果没有缓存则不自动拉取，直接返回
  /// [isManualRefresh] 为 true 时，表示用户手动点击了“从教务刷新”，会清除当前存档状态
  Future<void> loadCourses(
      {bool forceRefresh = false, bool onlyCache = false, bool clearUi = false, bool isManualRefresh = false}) async {
    if (_userId == null) return;

    final cacheKey = _currentCacheKey;
    final prefs = await SharedPreferences.getInstance();

    if (isManualRefresh) {
      await prefs.remove(_activeArchiveKey); // 手动刷新教务课表时，退出存档模式
    }

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

    final activeArchiveId = prefs.getString(_activeArchiveKey);
    // 如果当前处于“查看存档”模式，且不是用户主动的手动刷新，则跳过后续的网络拉取，防止存档被覆盖
    if (activeArchiveId != null && !isManualRefresh) {
      debugPrint('目前正在使用存档 $activeArchiveId，跳过后台静默同步');
      return;
    }

    await _loadHiddenCourses();

    // 缓存未命中或强制刷新 → 先清旧缓存，再请求网络
    if (forceRefresh) {
      await clearCache();
      if (clearUi) {
        _courses = [];
        _gridData = {};
      }
    }
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    // Step 1: 尝试服务器本地数据（包含用户自定义颜色/名称）
    bool localSuccess = false;
    try {
      final localResp = await _eduDio.get(
        '/api/edu/courses/local',
        queryParameters: {
          'user_id': _userId,
          'year': _selectedYear,
          'semester': _selectedSemester,
        },
      );

      if (localResp.statusCode == 200) {
        final data = localResp.data;
        final coursesJson = data['courses'] as List<dynamic>? ?? [];
        if (coursesJson.isNotEmpty) {
          _courses = coursesJson
              .map((c) => CourseBlock.fromJson(c as Map<String, dynamic>))
              .where((c) => c.id < 0 || !_hiddenCourseIds.contains(c.id))
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
                .where((c) => !_hiddenCourseIds.contains(c.id))
                .toList();
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
      await prefs.remove(_currentCacheKey);
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
    final newId = -(DateTime.now().millisecondsSinceEpoch * 100 + _courses.length); // 负数ID区分自定义课程

    final course = CourseBlock(
      id: newId,
      courseCode: 'CUSTOM',
      name: name,
      teacher: teacher,
      location: location,
      weekday: weekday,
      startSection: startSection,
      endSection: endSection,
      weeks: weeks,
      color: _colorPool[colorIdx],
    );

    _courses.insert(0, course);
    _buildGrid();

    if (_userId != null) {
      await _saveToCache(_currentCacheKey, _courses);
    }

    _syncWidget();
    notifyListeners();
    return course;
  }

  /// 编辑自定义课程
  Future<CourseBlock> editCustomCourse({
    required int id,
    required String name,
    required int weekday,
    required int startSection,
    required int endSection,
    required int startWeek,
    required int endWeek,
    String? teacher,
    String? location,
  }) async {
    final idx = _courses.indexWhere((c) => c.id == id);
    if (idx < 0) throw Exception('课程不存在');

    final weeks = List.generate(
      endWeek - startWeek + 1,
      (i) => startWeek + i,
    );
    final oldCourse = _courses[idx];

    final course = CourseBlock(
      id: oldCourse.id,
      courseCode: oldCourse.courseCode,
      name: name,
      teacher: teacher,
      location: location,
      weekday: weekday,
      startSection: startSection,
      endSection: endSection,
      weeks: weeks,
      color: oldCourse.color,
      note: oldCourse.note,
    );

    _courses[idx] = course;
    _buildGrid();

    if (_userId != null) {
      await _saveToCache(_currentCacheKey, _courses);
    }

    _syncWidget();
    notifyListeners();
    return course;
  }

  /// 删除课程（支持自定义课程和服务器课程）
  Future<void> removeCustomCourse(int courseId) async {
    _courses.removeWhere((c) => c.id == courseId);
    if (courseId > 0) {
      _hiddenCourseIds.add(courseId);
      await _saveHiddenCourses();
    }
    _buildGrid();
    if (_userId != null) {
      await _saveToCache(_currentCacheKey, _courses);
    }
    _syncWidget();
    notifyListeners();
  }

  void setSemester(String year, int semester) {
    _selectedYear = year;
    _selectedSemester = semester;
  }

  // ====== 存档管理 ======

  /// 从持久化存储加载存档列表
  Future<void> loadArchiveList() async {
    if (_userId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_archiveListKey);
      if (jsonStr != null) {
        final List<dynamic> list = jsonDecode(jsonStr);
        _archives = list.map((e) => CourseArchive.fromJson(e as Map<String, dynamic>)).toList();
      } else {
        _archives = [];
      }
      notifyListeners();
    } catch (e) {
      debugPrint('加载存档列表失败: $e');
      _archives = [];
    }
  }

  /// 保存当前课表为新存档
  Future<CourseArchive> saveCurrentAsArchive(String name) async {
    final id = 'archive_${DateTime.now().millisecondsSinceEpoch}';
    final archive = CourseArchive(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      courseCount: _courses.length,
    );

    // 保存课程数据
    final prefs = await SharedPreferences.getInstance();
    final coursesJson = jsonEncode(_courses.map((c) => c.toJson()).toList());
    await prefs.setString('$_archiveDataKeyPrefix$id', coursesJson);

    // 尝试备份到手机 Download 目录
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final dir = Directory('/storage/emulated/0/Download');
        if (await dir.exists()) {
          final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
          final file = File('${dir.path}/沈理校园课表_$safeName.json');
          await file.writeAsString(coursesJson);
          debugPrint('已自动备份到 Download 目录: ${file.path}');
        }
      }
    } catch (e) {
      debugPrint('备份到 Download 目录失败: $e');
    }

    // 更新存档列表
    _archives.insert(0, archive);
    await _saveArchiveList();
    notifyListeners();
    return archive;
  }

  /// 从外部 JSON 导入为新存档
  Future<void> importArchiveFromJson(String name, String jsonStr) async {
    final List<dynamic> list = jsonDecode(jsonStr);
    // 简单验证格式
    final courses = list.map((e) => CourseBlock.fromJson(e as Map<String, dynamic>)).toList();
    if (courses.isEmpty) throw Exception('课表数据为空或格式不正确');

    final id = 'archive_${DateTime.now().millisecondsSinceEpoch}';
    final archive = CourseArchive(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      courseCount: courses.length,
    );

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_archiveDataKeyPrefix$id', jsonEncode(courses.map((c) => c.toJson()).toList()));

    _archives.insert(0, archive);
    await _saveArchiveList();
    notifyListeners();
  }

  /// 载入指定存档
  Future<void> loadArchive(String archiveId) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('$_archiveDataKeyPrefix$archiveId');
    if (jsonStr == null) throw Exception('存档数据不存在');

    final List<dynamic> list = jsonDecode(jsonStr);
    _courses = list.map((e) => CourseBlock.fromJson(e as Map<String, dynamic>)).toList();
    _buildGrid();

    // 保存当前使用的存档ID
    await prefs.setString(_activeArchiveKey, archiveId);

    // 覆盖到当前 cache key，让下次打开直接展示
    await _saveToCache(_currentCacheKey, _courses);
    notifyListeners();
    _syncWidget();
  }

  /// 删除指定存档
  Future<void> deleteArchive(String archiveId) async {
    _archives.removeWhere((a) => a.id == archiveId);
    await _saveArchiveList();

    // 删除存档课程数据
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_archiveDataKeyPrefix$archiveId');
    notifyListeners();
  }

  /// 重命名存档
  Future<void> renameArchive(String archiveId, String newName) async {
    final idx = _archives.indexWhere((a) => a.id == archiveId);
    if (idx < 0) return;
    final old = _archives[idx];
    _archives[idx] = CourseArchive(
      id: old.id,
      name: newName,
      createdAt: old.createdAt,
      courseCount: old.courseCount,
    );
    await _saveArchiveList();
    notifyListeners();
  }

  Future<void> _saveArchiveList() async {
    if (_userId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_archives.map((a) => a.toJson()).toList());
      await prefs.setString(_archiveListKey, jsonStr);
    } catch (e) {
      debugPrint('保存存档列表失败: $e');
    }
  }
}
