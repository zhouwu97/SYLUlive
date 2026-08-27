import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../config/api_constants.dart';
import '../features/campus_data/storage/account_scoped_snapshot_store.dart';
import '../features/campus_data/storage/schedule_cache_store.dart';
import '../services/home_widget_service.dart';
import '../platform/platform_capabilities.dart';
import '../models/course_term.dart';

const _eduScheduleRequestTimeout = Duration(seconds: 25);

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
      name: (json['custom_name']?.toString() ??
          json['original_name']?.toString() ??
          json['name']?.toString() ??
          ''),
      teacher: json['teacher']?.toString(),
      location: json['location']?.toString(),
      color: json['color']?.toString() ?? '#6366F1',
      weekday: (json['weekday'] as num?)?.toInt() ?? 1,
      startSection: (json['start_section'] as num?)?.toInt() ?? 1,
      endSection: (json['end_section'] as num?)?.toInt() ?? 1,
      weeks: (json['weeks'] as List<dynamic>?)
              ?.map((e) => int.tryParse(e.toString()) ?? 0)
              .where((e) => e > 0)
              .toList() ??
          [],
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

/// 单次课表异步操作绑定的会话快照。
///
/// 网络请求、保险箱读写之间可能发生登录、来源账号或学期切换。操作必须始终
/// 使用发起时的 Store 和学期，并在每个异步边界后确认上下文仍然有效。
class _ScheduleOperationContext {
  const _ScheduleOperationContext({
    required this.generation,
    required this.appUserId,
    required this.sourceAccountId,
    required this.store,
    required this.storeReady,
    required this.year,
    required this.semester,
  });

  final int generation;
  final String appUserId;
  final String sourceAccountId;
  final ScheduleCacheStore? store;
  final Future<void> storeReady;
  final String year;
  final int semester;
}

/// 课表会话从认证身份到本地快照可用的阶段。
///
/// 课表为空并不等于当前用户真的没有课表：在来源账号尚未恢复、保险箱尚未
/// 打开或缓存尚未读取完成时，UI 必须保留正式框架，不能提前展示空状态 CTA。
enum ScheduleSessionPhase {
  resolvingIdentity,
  openingStore,
  restoringCache,
  ready,
}

/// 课表数据提供者 —— 只负责课程网格数据，不管理教务绑定
/// 绑定状态由 [EduProvider] 统一管理，本 Provider 只负责拉取和展示本地课程
class CourseScheduleProvider extends ChangeNotifier {
  final Dio _apiDio;
  final AccountScopedSnapshotStore Function(String appUserId)?
      _snapshotStoreBuilder;

  String? _userId;
  String? _sourceAccountId;
  ScheduleCacheStore? _scheduleStore;
  Future<void> _scheduleStoreReady = Future<void>.value();
  int _contextGeneration = 0;
  ScheduleSessionPhase _sessionPhase = ScheduleSessionPhase.resolvingIdentity;
  bool _isLoading = false;
  String? _errorMessage;

  // 学期管理
  CourseTerm? _currentTerm;

  CourseTerm get currentTerm => _currentTerm ?? CourseTerm.inferCurrentTerm();

  // 兼容旧的 getters
  String get selectedYear => currentTerm.year;
  int get selectedSemester => currentTerm.semester;
  DateTime? get semesterStart => currentTerm.startDate;

  // 课程数据
  List<CourseBlock> _courses = [];
  Map<int, Map<int, List<CourseBlock>>> _gridData = {};

  Set<int> _hiddenCourseIds = {};

  List<CourseArchive> _archives = [];

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  List<CourseBlock> get courses => _courses;
  Map<int, Map<int, List<CourseBlock>>> get gridData => _gridData;
  String? get userId => _userId;
  String? get cacheUserId => _userId;
  String? get sourceAccountId => _sourceAccountId;
  List<CourseArchive> get archives => _archives;
  ScheduleSessionPhase get sessionPhase => _sessionPhase;
  bool get isSessionReady => _sessionPhase == ScheduleSessionPhase.ready;
  int get contextGeneration => _contextGeneration;

  /// 页面层用于绑定一次性加载状态的稳定会话标识。
  ///
  /// 空来源账号是有意保留的：它表示认证用户已知，但教务身份仍在恢复，
  /// 不能与已完成绑定的 `appUserId::sourceAccountId` 混为同一会话。
  String get sessionKey => '${_userId ?? ''}::${_sourceAccountId ?? ''}';

  // 正常运行由 main 传入带认证拦截器的共享客户端；无参构造仅用于本地缓存测试。
  CourseScheduleProvider([
    Dio? dio,
    AccountScopedSnapshotStore Function(String appUserId)? snapshotStoreBuilder,
  ])  : _apiDio = dio ??
            Dio(
              BaseOptions(
                baseUrl: ApiConstants.baseUrl,
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(seconds: 60),
              ),
            ),
        _snapshotStoreBuilder = snapshotStoreBuilder {
    _initDefaults();
  }

  void _initDefaults() {
    _currentTerm = CourseTerm.inferCurrentTerm();
  }

  /// 兼容旧调用方：同一用户保留已确认的教务来源账号；新用户必须等待
  /// [syncSessionContext] 提供新的来源账号后才允许读写保险箱。
  void setUserId(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      clearAllUserState();
      return;
    }
    syncSessionContext(
      normalizedUserId,
      normalizedUserId == _userId ? _sourceAccountId : null,
    );
  }

  /// 同步当前认证用户和教务来源账号。
  ///
  /// 课表数据必须同时绑定两者；任一方变化都会同步清空内存，避免旧课程在
  /// 新账号或新学号上下文中短暂显示。
  void syncSessionContext(String? userId, String? sourceAccountId) {
    final normalizedUserId = userId?.trim() ?? '';
    final normalizedSourceAccountId = sourceAccountId?.trim() ?? '';
    if (normalizedUserId.isEmpty) {
      clearAllUserState();
      return;
    }
    if (_userId == normalizedUserId &&
        _sourceAccountId == normalizedSourceAccountId) {
      return;
    }

    _contextGeneration++;
    debugPrint('课表账号上下文已切换，清理旧内存数据');
    _courses = [];
    _gridData = {};
    _hiddenCourseIds = {};
    _archives = [];
    _errorMessage = null;
    _isLoading = false;
    _lastFetchedAt = null;
    _userId = normalizedUserId;
    _sourceAccountId = normalizedSourceAccountId;
    _currentTerm = CourseTerm.inferCurrentTerm();

    _scheduleStore = normalizedSourceAccountId.isEmpty
        ? null
        : ScheduleCacheStore(
            appUserId: normalizedUserId,
            sourceAccountId: normalizedSourceAccountId,
            snapshotStore: _snapshotStoreBuilder?.call(normalizedUserId),
          );
    final store = _scheduleStore;
    final generation = _contextGeneration;
    _sessionPhase = store == null
        ? ScheduleSessionPhase.resolvingIdentity
        : ScheduleSessionPhase.openingStore;
    _scheduleStoreReady = store == null
        ? Future<void>.value()
        : store.discardUnownedLegacy().catchError((Object error) {
            debugPrint('清理旧课表明文失败: ${error.runtimeType}');
          });

    if (store != null) {
      unawaited(_restoreSession(
        generation: generation,
        store: store,
      ));
    }
    notifyListeners();
  }

  bool _isCurrentSession(int generation, ScheduleCacheStore store) {
    return generation == _contextGeneration && identical(store, _scheduleStore);
  }

  /// 打开当前会话的保险箱并完成一次本地恢复。
  ///
  /// 这条链由 Provider 独占，页面不再通过 `setUserId` 或缓存 Future 参与
  /// session 绑定。即使 EduProvider 的来源账号晚于 App 用户 ID 到达，也会
  /// 产生新的 generation，并从正确 namespace 重新执行这里的恢复流程。
  Future<void> _restoreSession({
    required int generation,
    required ScheduleCacheStore store,
  }) async {
    try {
      await _scheduleStoreReady;
      if (!_isCurrentSession(generation, store)) return;

      _sessionPhase = ScheduleSessionPhase.restoringCache;
      notifyListeners();

      await loadSemesterStart();
      await loadArchiveList();
      await loadCachedCoursesIfAvailable();

      if (!_isCurrentSession(generation, store)) return;
      _sessionPhase = ScheduleSessionPhase.ready;
      notifyListeners();
    } catch (error) {
      // 缓存损坏或本地读失败不能让页面永久停在初始化态；ready 表示身份和
      // namespace 已确定，空课表仍由 UI 按正常 empty 状态处理，并允许用户重试。
      debugPrint('恢复课表本地会话失败: ${error.runtimeType}');
      if (!_isCurrentSession(generation, store)) return;
      _sessionPhase = ScheduleSessionPhase.ready;
      notifyListeners();
    }
  }

  /// 彻底清空当前用户所有内存状态（用于登出场景）
  void clearAllUserState() {
    _contextGeneration++;
    _userId = null;
    _sourceAccountId = null;
    _scheduleStore = null;
    _scheduleStoreReady = Future<void>.value();
    _sessionPhase = ScheduleSessionPhase.resolvingIdentity;
    _courses = [];
    _gridData = {};
    _hiddenCourseIds = {};
    _archives = [];
    _errorMessage = null;
    _lastFetchedAt = null;
    _currentTerm = null;
    _isLoading = false;
    notifyListeners();
  }

  void syncSessionUser(String? userId) {
    if (userId == null || userId.isEmpty) {
      clearAllUserState();
      return;
    }
    syncSessionContext(userId, _sourceAccountId);
  }

  _ScheduleOperationContext? _captureOperationContext([CourseTerm? term]) {
    final appUserId = _userId;
    if (appUserId == null || appUserId.isEmpty) return null;
    final selectedTerm = term ?? currentTerm;
    return _ScheduleOperationContext(
      generation: _contextGeneration,
      appUserId: appUserId,
      sourceAccountId: _sourceAccountId ?? '',
      store: _scheduleStore,
      storeReady: _scheduleStoreReady,
      year: selectedTerm.year,
      semester: selectedTerm.semester,
    );
  }

  bool _isCurrentOperation(_ScheduleOperationContext context) {
    return context.generation == _contextGeneration &&
        context.appUserId == _userId &&
        context.sourceAccountId == (_sourceAccountId ?? '') &&
        identical(context.store, _scheduleStore) &&
        context.year == selectedYear &&
        context.semester == selectedSemester;
  }

  Future<ScheduleCacheStore?> _resolveOperationStore(
    _ScheduleOperationContext context,
  ) async {
    final store = context.store;
    if (store == null) return null;
    await context.storeReady;
    return _isCurrentOperation(context) ? store : null;
  }

  Future<ScheduleTermSnapshot?> _loadOperationSnapshot(
    _ScheduleOperationContext context,
  ) async {
    final store = await _resolveOperationStore(context);
    if (store == null) return null;
    try {
      final snapshot = await store.readTerm(
        year: context.year,
        semester: context.semester,
      );
      return _isCurrentOperation(context) ? snapshot : null;
    } catch (error) {
      debugPrint('读取加密课表失败: ${error.runtimeType}');
      return null;
    }
  }

  Future<bool> _saveOperationCourses(
    _ScheduleOperationContext context,
    List<CourseBlock> courses,
  ) async {
    final store = await _resolveOperationStore(context);
    if (store == null) return false;
    try {
      await store.writeCourses(
        year: context.year,
        semester: context.semester,
        courses:
            courses.map((course) => course.toJson()).toList(growable: false),
      );
      return _isCurrentOperation(context);
    } catch (error) {
      debugPrint('保存加密课程失败: ${error.runtimeType}');
      return false;
    }
  }

  Future<bool> _saveOperationHiddenCourses(
    _ScheduleOperationContext context,
    Set<int> hiddenCourseIds,
  ) async {
    final store = await _resolveOperationStore(context);
    if (store == null) return false;
    try {
      await store.writeHiddenCourseIds(
        year: context.year,
        semester: context.semester,
        hiddenCourseIds: hiddenCourseIds,
      );
      return _isCurrentOperation(context);
    } catch (error) {
      debugPrint('保存加密隐藏课程失败: ${error.runtimeType}');
      return false;
    }
  }

  Future<bool> _saveOperationSemesterStart(
    _ScheduleOperationContext context,
    DateTime semesterStart,
  ) async {
    final store = await _resolveOperationStore(context);
    if (store == null) return false;
    try {
      await store.writeSemesterStart(
        year: context.year,
        semester: context.semester,
        semesterStart: semesterStart,
      );
      return _isCurrentOperation(context);
    } catch (error) {
      debugPrint('保存加密学期起始日期失败: ${error.runtimeType}');
      return false;
    }
  }

  Future<bool> _clearOperationActiveArchive(
    _ScheduleOperationContext context,
  ) async {
    final store = await _resolveOperationStore(context);
    if (store == null) return false;
    try {
      await store.clearActiveArchive(
        year: context.year,
        semester: context.semester,
      );
      return _isCurrentOperation(context);
    } catch (error) {
      debugPrint('清除加密课表存档状态失败: ${error.runtimeType}');
      return false;
    }
  }

  Future<bool> _clearOperationCourses(
    _ScheduleOperationContext context,
  ) async {
    final store = await _resolveOperationStore(context);
    if (store == null) return false;
    try {
      await store.clearCourses(
        year: context.year,
        semester: context.semester,
      );
      return _isCurrentOperation(context);
    } catch (error) {
      debugPrint('清除加密课程失败: ${error.runtimeType}');
      return false;
    }
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
    final cached = await _loadFromCache();
    return cached != null && cached.isNotEmpty;
  }

  Future<bool> loadCachedCoursesIfAvailable() async {
    final cached = await _loadFromCache();
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

  DateTime? _lastFetchedAt;

  /// 最近一次课表同步时间（来自保险箱快照 fetchedAt）；无缓存时为 null。
  DateTime? get lastFetchedAt => _lastFetchedAt;

  /// 读取保险箱快照的 fetchedAt 作为「上次同步」展示（无网络请求）。
  Future<DateTime?> loadLastFetchedAt() async {
    final operation = _captureOperationContext();
    if (operation == null) return null;
    final store = await _resolveOperationStore(operation);
    if (store == null || !_isCurrentOperation(operation)) return null;
    try {
      final snapshot = await store.readSnapshot();
      if (!_isCurrentOperation(operation) || snapshot == null) return null;
      _lastFetchedAt = snapshot.fetchedAt;
      return _lastFetchedAt;
    } catch (error) {
      debugPrint('读取课表同步时间失败: ${error.runtimeType}');
      return null;
    }
  }

  Future<int> applyFetchedCourses(
    List<Map<String, dynamic>> rawCourses, {
    bool resetHidden = false,
  }) async {
    final operation = _captureOperationContext();
    if (operation == null || operation.store == null) {
      debugPrint('课表导入已拒绝：缺少已验证的教务账号上下文');
      return 0;
    }
    if (await _resolveOperationStore(operation) == null) return 0;

    debugPrint(
      'Schedule applyFetchedCourses: '
      'term=${operation.year}_${operation.semester}, raw=${rawCourses.length}, '
      'hidden=${_hiddenCourseIds.length}',
    );

    if (resetHidden) {
      _hiddenCourseIds = {};
      if (!await _saveOperationHiddenCourses(operation, _hiddenCourseIds)) {
        return 0;
      }
    } else {
      final snapshot = await _loadOperationSnapshot(operation);
      if (!_isCurrentOperation(operation)) return 0;
      _hiddenCourseIds = snapshot?.hiddenCourseIds.toSet() ?? <int>{};
    }
    if (!_isCurrentOperation(operation)) return 0;

    final customCourses = _courses.where((c) => c.id < 0).toList();
    final parsedCourses = <CourseBlock>[...customCourses];
    int importedCount = 0;

    for (final rawCourse in rawCourses) {
      try {
        final parsed = _courseFromFetchedMap(rawCourse);
        if (!_hiddenCourseIds.contains(parsed.id)) {
          parsedCourses.add(parsed);
          importedCount++;
        }
      } catch (e) {
        debugPrint('解析课程失败: ${e.runtimeType}');
      }
    }

    debugPrint(
      'Schedule applyFetchedCourses done: '
      'imported=$importedCount, total=${parsedCourses.length}, '
      'cache namespace updated',
    );

    _courses = parsedCourses;
    _buildGrid();
    _isLoading = false;
    _errorMessage = null;

    if (_courses.isNotEmpty) {
      if (!await _saveOperationCourses(operation, _courses)) return 0;
    }
    if (!_isCurrentOperation(operation)) return 0;

    await _clearOperationActiveArchive(operation);
    if (!_isCurrentOperation(operation)) return 0;

    notifyListeners();
    _syncWidget();
    return importedCount;
  }

  CourseBlock _courseFromFetchedMap(Map<String, dynamic> map) {
    final name = _firstString(map, [
      'name',
      'course_name',
      'courseName',
      'kcmc',
      'title',
    ]);

    final time = _firstInt(
        map,
        [
          'time',
          'start_time',
          'startSection',
          'start_section',
          'jc_start',
        ],
        fallback: 1);

    final endTime = _firstInt(
        map,
        [
          'end_time',
          'endSection',
          'end_section',
          'jc_end',
        ],
        fallback: time);

    final weekday = _firstInt(
        map,
        [
          'week_day',
          'weekday',
          'dayOfWeek',
          'day_of_week',
          'xqj',
        ],
        fallback: 1);

    final teacher = _firstString(map, [
      'teacher',
      'teacher_name',
      'teacherName',
      'jsxm',
    ]);

    final loc = _firstString(map, ['location', 'classroom', 'room', 'jxdd']);

    final weeks = _parseWeeks(map['weeks'] ?? map['week_list'] ?? map['zcd']);

    // 生成稳定的正数 ID
    final idStr = '$name-$weekday-$time-$endTime-$teacher-$loc';
    int id = idStr.hashCode.abs();
    if (id == 0) id = 1;

    return CourseBlock(
      id: id,
      courseCode: '',
      name: name,
      teacher: teacher,
      location: loc,
      color: _colorPool[name.hashCode.abs() % _colorPool.length],
      weekday: weekday,
      startSection: time,
      endSection: endTime,
      weeks: weeks,
    );
  }

  String _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }
    return '';
  }

  int _firstInt(
    Map<String, dynamic> map,
    List<String> keys, {
    required int fallback,
  }) {
    for (final key in keys) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) {
        final text = value.trim();
        final direct = int.tryParse(text);
        if (direct != null) return direct;

        final match = RegExp(r'\d+').firstMatch(text);
        if (match != null) {
          final parsed = int.tryParse(match.group(0)!);
          if (parsed != null) return parsed;
        }
      }
    }
    return fallback;
  }

  List<int> _parseWeeks(Object? raw) {
    if (raw is List) {
      return raw
          .map((e) => _asInt(e, fallback: 0))
          .where((e) => e > 0)
          .toSet()
          .toList()
        ..sort();
    }

    if (raw is String) {
      final result = <int>{};
      final text = raw.replaceAll('周', '').replaceAll(' ', '');

      for (final part in text.split(',')) {
        if (part.contains('-')) {
          final seg = part.split('-');
          if (seg.length == 2) {
            final start = int.tryParse(seg[0]);
            final end = int.tryParse(seg[1]);
            if (start != null && end != null) {
              for (var i = start; i <= end; i++) {
                result.add(i);
              }
            }
          }
        } else {
          final v = int.tryParse(part);
          if (v != null) result.add(v);
        }
      }

      return result.toList()..sort();
    }

    return <int>[];
  }

  int _asInt(Object? value, {required int fallback}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  Future<void> _saveHiddenCourses() async {
    final operation = _captureOperationContext();
    if (operation == null) return;
    await _saveOperationHiddenCourses(operation, _hiddenCourseIds);
  }

  /// 拉取课程。默认优先缓存。
  /// [forceRefresh] 强制拉取（用于静默同步或手动刷新）
  /// [onlyCache] 为 true 时，如果没有缓存则不自动拉取，直接返回
  /// [isManualRefresh] 为 true 时，表示用户手动点击了“从教务刷新”，会清除当前存档状态
  Future<void> loadCourses({
    bool forceRefresh = false,
    bool onlyCache = false,
    bool clearUi = false,
    bool isManualRefresh = false,
  }) async {
    final operation = _captureOperationContext();
    if (operation == null || operation.store == null) return;
    if (await _resolveOperationStore(operation) == null) return;

    if (isManualRefresh) {
      await _clearOperationActiveArchive(operation);
      if (!_isCurrentOperation(operation)) return;
    }

    // 保留刷新前的课程数据作为备份
    final backupCourses = List<CourseBlock>.from(_courses);

    // 非强制刷新时，先尝试手机缓存
    if (!forceRefresh) {
      final snapshot = await _loadOperationSnapshot(operation);
      if (!_isCurrentOperation(operation)) return;
      final cached =
          snapshot?.courses.map(CourseBlock.fromJson).toList(growable: false);
      if (cached != null && cached.isNotEmpty) {
        _courses = cached;
        _buildGrid();
        debugPrint('从手机缓存加载课程: count=${_courses.length}');
        _isLoading = false;
        notifyListeners();
        _syncWidget(); // 更新桌面小部件
        debugPrint('课表缓存加载完成: count=${_courses.length}');
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

    final activeArchiveId =
        (await _loadOperationSnapshot(operation))?.activeArchiveId;
    if (!_isCurrentOperation(operation)) return;
    // 如果当前处于“查看存档”模式，且不是用户主动的手动刷新，则跳过后续的网络拉取，防止存档被覆盖
    if (activeArchiveId != null && !isManualRefresh) {
      debugPrint('当前处于课表存档模式，跳过后台静默同步');
      return;
    }

    final hiddenSnapshot = await _loadOperationSnapshot(operation);
    if (!_isCurrentOperation(operation)) return;
    _hiddenCourseIds = hiddenSnapshot?.hiddenCourseIds.toSet() ?? <int>{};

    // 缓存未命中或强制刷新 → 准备网络请求
    if (forceRefresh) {
      if (clearUi) {
        _courses = [];
        _gridData = {};
      }
    }
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    bool networkSuccess = false;

    // 原始课表只通过教务代理按需获取。成功后写入当前账号的本地加密
    // 保险箱，不能读取服务端持久化副本，避免个人课程数据回流到服务端。
    try {
      final fetchResp = await _apiDio.post(
        '/edu/courses',
        data: {'year': operation.year, 'semester': operation.semester},
        options: Options(receiveTimeout: _eduScheduleRequestTimeout),
      );
      if (!_isCurrentOperation(operation)) return;

      if (fetchResp.statusCode == 200 && fetchResp.data is Map) {
        final data = fetchResp.data;
        if (data['success'] == true) {
          final rawCourses = data['courses'] as List<dynamic>? ?? [];
          if (rawCourses.isEmpty &&
              backupCourses.isNotEmpty &&
              !isManualRefresh) {
            // 自动刷新拉取到空课表时，保留已验证的本地数据，避免教务端
            // 短暂异常覆盖当前用户的加密缓存。
            debugPrint('教务系统返回空课表，保留当前本地课程');
            _courses = backupCourses;
            _buildGrid();
          } else {
            _courses = rawCourses
                .map((c) => _courseFromFetchedMap(c as Map<String, dynamic>))
                .where((c) => !_hiddenCourseIds.contains(c.id))
                .toList();
            _buildGrid();
            networkSuccess = true;
          }
          debugPrint('从教务拉取课程: count=${_courses.length}');
        } else {
          _errorMessage = data['message'] as String?;
        }
      }
    } on DioException catch (e) {
      if (!_isCurrentOperation(operation)) return;
      _errorMessage = _parseDioError(e);
      debugPrint(
        '从教务拉取课程失败: type=${e.type}, status=${e.response?.statusCode}',
      );
    } catch (error) {
      if (!_isCurrentOperation(operation)) return;
      _errorMessage = '解析课表数据失败';
      debugPrint('解析教务课表失败: ${error.runtimeType}');
    }
    if (!_isCurrentOperation(operation)) return;

    // 网络请求成功后，保存或清理缓存
    if (networkSuccess) {
      // 恢复所有本地的自定义课程 (包括 AI 导入的课程，其 id 均为负数)
      final customCourses = backupCourses.where((c) => c.id < 0).toList();
      if (customCourses.isNotEmpty) {
        _courses.addAll(customCourses);
        _buildGrid();
      }

      final persisted = _courses.isNotEmpty
          ? await _saveOperationCourses(operation, _courses)
          : await _clearOperationCourses(operation);
      if (!_isCurrentOperation(operation)) return;
      if (!persisted) {
        _errorMessage = '课程已获取，但未能安全保存，请稍后重试';
      }
    }

    if (!networkSuccess && backupCourses.isNotEmpty) {
      _courses = backupCourses;
      _buildGrid();
    }

    _isLoading = false;
    notifyListeners();
    _syncWidget(); // 更新桌面小部件
    debugPrint('课表网络拉取完成: count=${_courses.length}');
  }

  /// 同步课程数据到桌面小部件（非阻塞）
  void _syncWidget() {
    if (_userId == null) return;
    if (!PlatformCapabilities.current.supportsNativeWidget) return;
    // 使用 microtask 避免阻塞 UI
    Future.microtask(() => HomeWidgetService.syncCourseData(this));
  }

  /// 保存课程到当前账号和来源账号绑定的 AES-GCM 保险箱。
  Future<void> _saveToCache(List<CourseBlock> courses) async {
    final operation = _captureOperationContext();
    if (operation == null) return;
    await _saveOperationCourses(operation, courses);
  }

  /// 只从当前账号和来源账号绑定的 AES-GCM 快照读取课程。
  Future<List<CourseBlock>?> _loadFromCache() async {
    try {
      final operation = _captureOperationContext();
      if (operation == null) return null;
      final snapshot = await _loadOperationSnapshot(operation);
      if (!_isCurrentOperation(operation)) return null;
      if (snapshot == null || snapshot.courses.isEmpty) return null;
      return snapshot.courses.map(CourseBlock.fromJson).toList();
    } catch (error) {
      debugPrint('读取加密课程失败: ${error.runtimeType}');
      return null;
    }
  }

  /// 清除当前学期的加密课程，但保留同学期的用户存档和隐藏状态。
  Future<void> clearCache() async {
    final operation = _captureOperationContext();
    if (operation == null) return;
    await _clearOperationCourses(operation);
  }

  String _parseDioError(DioException e) {
    if (e.response != null) {
      switch (e.response!.statusCode) {
        case 401:
          return '教务登录状态已失效，请重新登录';
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

  /// 设置学期起始日期（周一），持久化到加密课表快照。
  Future<void> setSemesterStart(DateTime date) async {
    final operation = _captureOperationContext();
    if (operation == null || operation.store == null) return;

    // 对齐到周一
    final start = DateTime(
      date.year,
      date.month,
      date.day,
    ).subtract(Duration(days: date.weekday - 1));

    if (!await _saveOperationSemesterStart(operation, start)) return;
    if (!_isCurrentOperation(operation)) return;
    _currentTerm = currentTerm.copyWith(startDate: start);
    notifyListeners();
  }

  /// 从加密课表快照加载当前学期起始日期。
  Future<void> loadSemesterStart() async {
    final operation = _captureOperationContext();
    if (operation == null) return;
    final snapshot = await _loadOperationSnapshot(operation);
    if (!_isCurrentOperation(operation)) return;
    final start = snapshot?.semesterStart;
    _currentTerm = currentTerm.copyWith(
      startDate:
          start == null ? null : DateTime(start.year, start.month, start.day),
    );
  }

  /// 计算给定日期对应的教学周号（1-based），未设置则返回 null
  int? getAcademicWeek(DateTime date) {
    if (semesterStart == null) return null;
    final diff = date.difference(semesterStart!).inDays;
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
    final weeks = List.generate(endWeek - startWeek + 1, (i) => startWeek + i);
    final colorIdx = name.hashCode.abs() % _colorPool.length;
    final newId = -(DateTime.now().millisecondsSinceEpoch * 100 +
        _courses.length); // 负数ID区分自定义课程

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
      await _saveToCache(_courses);
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

    final weeks = List.generate(endWeek - startWeek + 1, (i) => startWeek + i);
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
      await _saveToCache(_courses);
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
      await _saveToCache(_courses);
    }
    _syncWidget();
    notifyListeners();
  }

  CourseTerm buildTerm(String year, int semester) {
    final inferred = CourseTerm.inferCurrentTerm();
    final id = '${year}_$semester';
    return CourseTerm(
      id: id,
      year: year,
      semester: semester,
      title: CourseTermCatalog.titleFor(year, semester),
      isCurrent: id == inferred.id,
      maxWeek: 20,
    );
  }

  Future<bool> switchTerm(CourseTerm term, {bool loadCache = true}) async {
    if (_userId == null) return false;

    _currentTerm = term;
    _courses = [];
    _gridData = {};
    _hiddenCourseIds = {};
    _archives = [];
    _errorMessage = null;
    _isLoading = false;

    await loadSemesterStart();
    await loadArchiveList();

    bool hasCache = false;
    if (loadCache) {
      hasCache = await loadCachedCoursesIfAvailable();
    } else {
      notifyListeners();
    }

    _syncWidget();
    return hasCache;
  }

  Future<bool> selectTerm(
    String year,
    int semester, {
    bool clearCurrent = true,
  }) async {
    final term = buildTerm(year, semester);

    if (!clearCurrent &&
        currentTerm.year == year &&
        currentTerm.semester == semester) {
      await loadSemesterStart();
      await loadArchiveList();
      return courses.isNotEmpty || await loadCachedCoursesIfAvailable();
    }

    return switchTerm(term, loadCache: true);
  }

  Future<int> applyFetchedCoursesForTerm({
    required CourseTerm term,
    required List<Map<String, dynamic>> rawCourses,
    bool resetHidden = true,
  }) async {
    if (_userId == null) return 0;

    _currentTerm = term;
    final operation = _captureOperationContext(term);
    if (operation == null || operation.store == null) return 0;

    final snapshot = await _loadOperationSnapshot(operation);
    if (!_isCurrentOperation(operation)) return 0;
    final semesterStart = snapshot?.semesterStart;
    _currentTerm = currentTerm.copyWith(
      startDate: semesterStart == null
          ? null
          : DateTime(
              semesterStart.year,
              semesterStart.month,
              semesterStart.day,
            ),
    );
    _archives = (snapshot?.archives ?? const <ScheduleArchiveSnapshot>[])
        .map(
          (archive) => CourseArchive(
            id: archive.id,
            name: archive.name,
            createdAt: archive.createdAt.toLocal(),
            courseCount: archive.courseCount,
          ),
        )
        .toList(growable: false);

    await _clearOperationActiveArchive(operation);
    if (!_isCurrentOperation(operation)) return 0;

    _courses = snapshot?.courses.map(CourseBlock.fromJson).toList() ?? [];
    _buildGrid();

    return applyFetchedCourses(rawCourses, resetHidden: resetHidden);
  }

  // ====== 存档管理 ======

  /// 从持久化存储加载存档列表
  Future<void> loadArchiveList() async {
    final operation = _captureOperationContext();
    if (operation == null) return;
    final snapshot = await _loadOperationSnapshot(operation);
    if (!_isCurrentOperation(operation)) return;
    _archives = (snapshot?.archives ?? const <ScheduleArchiveSnapshot>[])
        .map(
          (archive) => CourseArchive(
            id: archive.id,
            name: archive.name,
            createdAt: archive.createdAt.toLocal(),
            courseCount: archive.courseCount,
          ),
        )
        .toList(growable: false);
    notifyListeners();
  }

  /// 保存当前课表为新存档
  Future<CourseArchive> saveCurrentAsArchive(String name) async {
    final operation = _captureOperationContext();
    if (operation == null) {
      throw StateError('课表存档缺少有效的账号上下文');
    }
    final store = await _resolveOperationStore(operation);
    if (store == null) {
      throw StateError('课表存档缺少有效的账号上下文');
    }
    final id = 'archive_${DateTime.now().millisecondsSinceEpoch}';
    final archive = CourseArchive(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      courseCount: _courses.length,
    );

    await store.saveArchive(
      year: operation.year,
      semester: operation.semester,
      archive: ScheduleArchiveSnapshot(
        id: archive.id,
        name: archive.name,
        createdAt: archive.createdAt,
        courseCount: archive.courseCount,
        courses:
            _courses.map((course) => course.toJson()).toList(growable: false),
      ),
    );
    if (!_isCurrentOperation(operation)) {
      throw StateError('课表账号上下文已切换');
    }
    _archives.insert(0, archive);
    notifyListeners();
    return archive;
  }

  /// 从外部 JSON 导入为新存档
  Future<void> importArchiveFromJson(String name, String jsonStr) async {
    final operation = _captureOperationContext();
    if (operation == null) {
      throw StateError('课表存档缺少有效的账号上下文');
    }
    final store = await _resolveOperationStore(operation);
    if (store == null) {
      throw StateError('课表存档缺少有效的账号上下文');
    }
    final List<dynamic> list = jsonDecode(jsonStr);
    // 简单验证格式
    final courses = list
        .map((e) => CourseBlock.fromJson(e as Map<String, dynamic>))
        .toList();
    if (courses.isEmpty) throw Exception('课表数据为空或格式不正确');

    final id = 'archive_${DateTime.now().millisecondsSinceEpoch}';
    final archive = CourseArchive(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      courseCount: courses.length,
    );

    await store.saveArchive(
      year: operation.year,
      semester: operation.semester,
      archive: ScheduleArchiveSnapshot(
        id: archive.id,
        name: archive.name,
        createdAt: archive.createdAt,
        courseCount: archive.courseCount,
        courses:
            courses.map((course) => course.toJson()).toList(growable: false),
      ),
    );
    if (!_isCurrentOperation(operation)) {
      throw StateError('课表账号上下文已切换');
    }

    _archives.insert(0, archive);
    notifyListeners();
  }

  /// 载入指定存档
  Future<void> loadArchive(String archiveId) async {
    final operation = _captureOperationContext();
    if (operation == null) {
      throw StateError('课表存档缺少有效的账号上下文');
    }
    final store = await _resolveOperationStore(operation);
    if (store == null) {
      throw StateError('课表存档缺少有效的账号上下文');
    }
    final snapshot = await _loadOperationSnapshot(operation);
    if (!_isCurrentOperation(operation)) {
      throw StateError('课表账号上下文已切换');
    }
    ScheduleArchiveSnapshot? archive;
    for (final candidate
        in snapshot?.archives ?? const <ScheduleArchiveSnapshot>[]) {
      if (candidate.id == archiveId) {
        archive = candidate;
        break;
      }
    }
    if (archive == null) throw Exception('课表存档数据不存在');

    await store.activateArchive(
      year: operation.year,
      semester: operation.semester,
      archiveId: archiveId,
    );
    if (!_isCurrentOperation(operation)) return;

    _courses = archive.courses.map(CourseBlock.fromJson).toList();
    _buildGrid();
    await _saveOperationCourses(operation, _courses);
    if (!_isCurrentOperation(operation)) return;
    notifyListeners();
    _syncWidget();
  }

  /// 删除指定存档
  Future<void> deleteArchive(String archiveId) async {
    final operation = _captureOperationContext();
    if (operation == null) return;
    final store = await _resolveOperationStore(operation);
    if (store == null) return;
    await store.deleteArchive(
      year: operation.year,
      semester: operation.semester,
      archiveId: archiveId,
    );
    if (!_isCurrentOperation(operation)) return;
    _archives.removeWhere((a) => a.id == archiveId);
    notifyListeners();
  }

  /// 重命名存档
  Future<void> renameArchive(String archiveId, String newName) async {
    final operation = _captureOperationContext();
    if (operation == null) return;
    final idx = _archives.indexWhere((a) => a.id == archiveId);
    if (idx < 0) return;
    final old = _archives[idx];
    final renamed = CourseArchive(
      id: old.id,
      name: newName,
      createdAt: old.createdAt,
      courseCount: old.courseCount,
    );
    final store = await _resolveOperationStore(operation);
    if (store == null) return;
    await store.renameArchive(
      year: operation.year,
      semester: operation.semester,
      archiveId: archiveId,
      newName: newName,
    );
    if (!_isCurrentOperation(operation)) return;
    _archives[idx] = renamed;
    notifyListeners();
  }
}
