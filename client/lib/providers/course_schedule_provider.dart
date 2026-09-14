import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide CourseSource;
import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/domain/academic_failure.dart';
import '../features/academic/domain/academic_provider.dart';
import '../features/academic/domain/academic_repository.dart';
import '../features/campus_data/storage/account_scoped_snapshot_store.dart';
import '../features/campus_data/storage/schedule_cache_store.dart';
import '../features/academic/storage/academic_persistence_gate.dart';
import '../services/home_widget_service.dart';
import '../platform/platform_capabilities.dart';
import '../models/course_term.dart';
import '../utils/deterministic_course_id.dart';
import '../models/schedule/course.dart';
import '../models/schedule/course_source.dart';
import '../models/schedule/meeting.dart';
import '../models/schedule/schedule_override.dart';
import '../models/schedule/resolved_meeting.dart';
import '../services/schedule/schedule_resolver.dart';
import '../services/schedule/meeting_reconciler.dart';
import '../services/schedule/schedule_conflict_service.dart';
import '../repositories/schedule_override_repository.dart';

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

  /// Provider 原始排课行序和标签；本科课程没有这组字段。
  final int? periodOrder;
  final String? periodLabel;

  /// 课程块覆盖的 Provider 原始节次标签。
  ///
  /// 研究生相邻节次归并后仍保留每一行的原标签，供详情展示与数据回溯使用。
  final List<String> periodLabels;

  final bool isOverridden;
  final String? overrideId;
  final Set<int> conflictWeeks;
  final bool? _legacyHasConflict;

  bool hasConflictAtWeek(int week) => conflictWeeks.contains(week);
  bool get hasConflict => _legacyHasConflict ?? conflictWeeks.isNotEmpty;
  final String? courseKey;
  final String? meetingKey;
  final String? teachingClassId;
  final String? source;

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
    this.periodOrder,
    this.periodLabel,
    this.periodLabels = const <String>[],
    this.isOverridden = false,
    this.overrideId,
    this.conflictWeeks = const <int>{},
    bool? hasConflict,
    this.courseKey,
    this.meetingKey,
    this.teachingClassId,
    this.source,
  }) : _legacyHasConflict = hasConflict;

  int get span => endSection - startSection + 1;

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
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
    if (periodOrder != null) json['period_order'] = periodOrder;
    final label = periodLabel?.trim();
    if (label != null && label.isNotEmpty) json['period_label'] = label;
    if (periodLabels.isNotEmpty) {
      json['period_labels'] = periodLabels;
    }
    if (isOverridden) json['is_overridden'] = true;
    if (overrideId != null) json['override_id'] = overrideId;
    if (hasConflict) json['has_conflict'] = true;
    if (conflictWeeks.isNotEmpty) {
      json['conflict_weeks'] = conflictWeeks.toList()..sort();
    }
    if (courseKey != null) json['course_key'] = courseKey;
    if (meetingKey != null) json['meeting_key'] = meetingKey;
    if (teachingClassId != null) json['teaching_class_id'] = teachingClassId;
    if (source != null) json['source'] = source;
    return json;
  }

  factory CourseBlock.fromJson(Map<String, dynamic> json) {
    final rawPeriodOrder = json['period_order'] ?? json['periodOrder'];
    final periodOrder = switch (rawPeriodOrder) {
      num value => value.toInt(),
      _ => int.tryParse(rawPeriodOrder?.toString().trim() ?? ''),
    };
    final rawPeriodLabel =
        (json['period_label'] ?? json['periodLabel'])?.toString().trim();
    final parsedPeriodLabels =
        switch (json['period_labels'] ?? json['periodLabels']) {
      final List<dynamic> values => values
          .map((value) => value.toString().trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      _ => <String>[],
    };
    final periodLabels = parsedPeriodLabels.isNotEmpty
        ? parsedPeriodLabels
        : rawPeriodLabel != null && rawPeriodLabel.isNotEmpty
            ? <String>[rawPeriodLabel]
            : const <String>[];
    final isOverridden = json['is_overridden'] == true;
    final overrideId = json['override_id']?.toString();
    final rawConflictWeeks = (json['conflict_weeks'] as List<dynamic>?)
            ?.map((e) => int.tryParse(e.toString()) ?? 0)
            .where((e) => e > 0)
            .toSet() ??
        const <int>{};
    final hasConflict = json['has_conflict'] == true;
    final courseKey = json['course_key']?.toString();
    final meetingKey = json['meeting_key']?.toString();
    final teachingClassId = json['teaching_class_id']?.toString();
    final source = json['source']?.toString();

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
      periodOrder: periodOrder,
      periodLabel: rawPeriodLabel == null || rawPeriodLabel.isEmpty
          ? null
          : rawPeriodLabel,
      periodLabels: periodLabels,
      isOverridden: isOverridden,
      overrideId: overrideId,
      conflictWeeks: rawConflictWeeks,
      hasConflict: hasConflict,
      courseKey: courseKey,
      meetingKey: meetingKey,
      teachingClassId: teachingClassId,
      source: source,
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
    this.providerTermId,
  });

  final int generation;
  final String appUserId;
  final String sourceAccountId;
  final ScheduleCacheStore? store;
  final Future<void> storeReady;
  final String year;
  final int semester;
  final String? providerTermId;
}

/// 课表会话从认证身份到本地快照可用的阶段。
///
/// 课表为空并不等于当前用户真的没有课表：在来源账号尚未恢复、保险箱尚未
/// 打开或缓存尚未读取完成时，UI 必须保留正式框架，不能提前展示空状态 CTA。
enum ScheduleSessionPhase {
  resolvingIdentity,
  openingStore,
  restoringCache,
  restoreFailed,
  ready,
}

/// 课表数据提供者 —— 只负责课程网格数据，不管理教务绑定
/// 绑定状态由 [EduProvider] 统一管理，本 Provider 只负责拉取和展示本地课程
class CourseScheduleProvider extends ChangeNotifier {
  final AcademicRepository? _academicRepository;
  final AcademicSessionController? _academicSessionController;
  final AccountScopedSnapshotStore Function(String appUserId)?
      _snapshotStoreBuilder;

  String? _userId;
  String? _sourceAccountId;
  String? _identityNamespace;
  AcademicIdentityKey? get academicIdentity =>
      _academicSessionController?.identity;
  ScheduleCacheStore? _scheduleStore;
  Future<void> _scheduleStoreReady = Future<void>.value();
  int _contextGeneration = 0;
  ScheduleSessionPhase _sessionPhase = ScheduleSessionPhase.resolvingIdentity;
  bool _isLoading = false;
  String? _errorMessage;
  bool _legacyCacheRequiresResync = false;
  bool _sourceTrustKnown = false;
  Future<void> _sessionRestoreFuture = Future<void>.value();
  bool _disposed = false;

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

  // 课程底层结构与本地调整规则
  List<Course> _baseSchedule = [];
  List<ScheduleOverride> _overrides = [];
  List<Course> _manualCourses = [];
  List<ResolvedMeeting> _resolvedMeetings = [];

  final ScheduleResolver _scheduleResolver = const ScheduleResolver();
  final MeetingReconciler _meetingReconciler = const MeetingReconciler();
  final ScheduleOverrideRepository _overrideRepository =
      ScheduleOverrideRepository();
  final ScheduleConflictService _conflictService =
      const ScheduleConflictService();

  List<ResolvedMeeting> get resolvedMeetings => _resolvedMeetings;
  List<ScheduleOverride> get overrides => _overrides;
  List<Course> get baseSchedule => _baseSchedule;
  List<Course> get manualCourses => _manualCourses;

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
  bool get legacyCacheRequiresResync => _legacyCacheRequiresResync;

  /// 研究生 Provider 的节次标签不是本科课表的数字时钟，布局必须保留
  /// Provider 行序；即使当前学期没有课程，也不能回退到本科时间轴。
  bool get usesProviderPeriodLayout =>
      _academicSessionController?.providerId ==
          AcademicProviderId.syluGraduate ||
      _courses.any(
        (course) =>
            course.periodOrder != null ||
            (course.periodLabel?.trim().isNotEmpty ?? false),
      );

  /// 返回课表网格需要的行数。本科保持历史 12 节；研究生按原始行序扩展，
  /// 支持稀疏节次和超过 12 行的学校课表。
  int get periodSlotCount {
    if (!usesProviderPeriodLayout) return 12;
    var maxOrder = -1;
    var maxSection = 0;
    for (final course in _courses) {
      final order = course.periodOrder;
      if (order != null && order >= 0 && order > maxOrder) {
        maxOrder = order;
      }
      if (course.endSection > maxSection) maxSection = course.endSection;
    }
    final countFromOrder = maxOrder + 1;
    final count = countFromOrder > maxSection ? countFromOrder : maxSection;
    return count > 0 ? count : 1;
  }

  /// 页面层用于绑定一次性加载状态的稳定会话标识。
  ///
  /// 空来源账号是有意保留的：它表示认证用户已知，但教务身份仍在恢复，
  /// 不能与已完成绑定的 `appUserId::sourceAccountId` 混为同一会话。
  String get sessionKey => '${_userId ?? ''}::${_sourceAccountId ?? ''}';

  // 保留旧构造参数以兼容调用方；教务请求统一由本机会话控制器处理。
  CourseScheduleProvider([
    Dio? legacyDio,
    AccountScopedSnapshotStore Function(String appUserId)? snapshotStoreBuilder,
    AcademicRepository? academicRepository,
    AcademicSessionController? academicSessionController,
  ])  : _snapshotStoreBuilder = snapshotStoreBuilder,
        _academicRepository = academicRepository,
        _academicSessionController = academicSessionController {
    _initDefaults();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
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
    final normalizedIdentityNamespace =
        _academicSessionController?.identity?.storageId;
    if (normalizedUserId.isEmpty) {
      clearAllUserState();
      return;
    }
    if (_userId == normalizedUserId &&
        _sourceAccountId == normalizedSourceAccountId &&
        _identityNamespace == normalizedIdentityNamespace) {
      return;
    }

    _contextGeneration++;
    debugPrint('课表账号上下文已切换，清理旧内存数据');
    _courses = [];
    _gridData = {};
    // 账号/来源切换时必须连同解析链路一起清空，避免新账号无缓存时复用旧账号。
    _baseSchedule = [];
    _overrides = [];
    _manualCourses = [];
    _resolvedMeetings = [];
    _hiddenCourseIds = {};
    _archives = [];
    _errorMessage = null;
    _legacyCacheRequiresResync = false;
    _sourceTrustKnown = false;
    _isLoading = false;
    _lastFetchedAt = null;
    _userId = normalizedUserId;
    _sourceAccountId = normalizedSourceAccountId;
    _identityNamespace = normalizedIdentityNamespace;
    _currentTerm = CourseTerm.inferCurrentTerm();

    _scheduleStore = normalizedSourceAccountId.isEmpty
        ? null
        : ScheduleCacheStore(
            appUserId: normalizedUserId,
            sourceAccountId: normalizedSourceAccountId,
            identityNamespace: normalizedIdentityNamespace,
            snapshotStore: _snapshotStoreBuilder?.call(normalizedUserId),
            persistenceGate: RegistryAcademicPersistenceGate(normalizedUserId),
          );
    final store = _scheduleStore;
    final generation = _contextGeneration;
    _sessionPhase = store == null
        ? ScheduleSessionPhase.resolvingIdentity
        : ScheduleSessionPhase.openingStore;
    _scheduleStoreReady = store == null
        ? Future<void>.value()
        : store.discardUnownedLegacy().catchError((Object error) {
            debugPrint('丢弃旧课表失败: ${error.runtimeType}');
          });

    if (store != null) {
      _sessionRestoreFuture = _restoreSession(
        generation: generation,
        store: store,
      );
      unawaited(_sessionRestoreFuture);
    }
    notifyListeners();
  }

  bool _isCurrentSession(int generation, ScheduleCacheStore store) {
    return !_disposed &&
        generation == _contextGeneration &&
        identical(store, _scheduleStore);
  }

  /// 打开当前会话的保险箱并完成一次本地恢复。
  Future<void> retryLocalRestore() async {
    final store = _scheduleStore;
    if (store == null || _disposed) return;
    final generation = ++_contextGeneration;
    await _restoreSession(generation: generation, store: store);
  }

  /// 本地恢复独立于学校会话，不触发学校请求。
  ///
  /// 这条链由 Provider 独占，页面不再通过 `setUserId` 或缓存 Future 参与
  /// session 绑定。即使 EduProvider 的来源账号晚于 App 用户 ID 到达，也会
  /// 产生新的 generation，并从正确 namespace 重新执行这里的恢复流程。
  Future<void> _restoreSession({
    required int generation,
    required ScheduleCacheStore store,
    bool retryTransientFailure = true,
  }) async {
    try {
      await _scheduleStoreReady;
      if (!_isCurrentSession(generation, store)) return;

      _sessionPhase = ScheduleSessionPhase.restoringCache;
      _errorMessage = null;
      notifyListeners();

      await _restoreSelectedTerm(generation, store);
      if (!_isCurrentSession(generation, store)) return;
      await loadSemesterStart();
      await loadArchiveList();
      await loadCachedCoursesIfAvailable();

      if (!_isCurrentSession(generation, store)) return;
      _sessionPhase = ScheduleSessionPhase.ready;
      notifyListeners();
    } catch (error) {
      // 读取失败不能当作缓存不存在。保留密文及现有课程，允许恢复前台或用户重试。
      debugPrint('恢复课表本地会话失败: ${error.runtimeType}');
      if (!_isCurrentSession(generation, store)) return;
      // 进程恢复时平台密钥/文件通道可能尚未就绪，只补一次本地重读，不访问学校。
      if (retryTransientFailure) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (!_isCurrentSession(generation, store)) return;
        return _restoreSession(
          generation: generation,
          store: store,
          retryTransientFailure: false,
        );
      }
      _sessionPhase = ScheduleSessionPhase.restoreFailed;
      _errorMessage = '本机课表暂时无法读取，已保存的数据未删除，请重试恢复';
      notifyListeners();
    }
  }

  Future<void> _restoreSelectedTerm(
    int generation,
    ScheduleCacheStore store,
  ) async {
    final selected = await store.readSelectedTerm();
    if (!_isCurrentSession(generation, store) || selected == null) return;
    try {
      final term = CourseTerm.fromJson(selected);
      if (term.id.trim().isEmpty ||
          term.year.trim().isEmpty ||
          term.semester <= 0 ||
          term.title.trim().isEmpty) {
        return;
      }
      _currentTerm = term;
    } catch (error) {
      debugPrint('恢复课表选中学期失败: ${error.runtimeType}');
    }
  }

  /// 彻底清空当前用户所有内存状态（用于登出场景）
  void clearAllUserState() {
    _contextGeneration++;
    _userId = null;
    _sourceAccountId = null;
    _identityNamespace = null;
    _scheduleStore = null;
    _scheduleStoreReady = Future<void>.value();
    _sessionRestoreFuture = Future<void>.value();
    _sessionPhase = ScheduleSessionPhase.resolvingIdentity;
    _courses = [];
    _gridData = {};
    _baseSchedule = [];
    _overrides = [];
    _manualCourses = [];
    _resolvedMeetings = [];
    _hiddenCourseIds = {};
    _archives = [];
    _errorMessage = null;
    _legacyCacheRequiresResync = false;
    _sourceTrustKnown = false;
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
      providerTermId: selectedTerm.providerTermId,
    );
  }

  bool _isCurrentOperation(_ScheduleOperationContext context) {
    return !_disposed &&
        context.generation == _contextGeneration &&
        context.appUserId == _userId &&
        context.sourceAccountId == (_sourceAccountId ?? '') &&
        identical(context.store, _scheduleStore) &&
        context.year == selectedYear &&
        context.semester == selectedSemester &&
        context.providerTermId == currentTerm.providerTermId;
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
      if (_isCurrentOperation(context) &&
          _sessionPhase == ScheduleSessionPhase.restoringCache) {
        rethrow;
      }
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
      final baseBlocks = _courseModelsToBlocks(_baseSchedule);
      final manualBlocks = _courseModelsToBlocks(_manualCourses);
      await store.writeSourceCourses(
        year: context.year,
        semester: context.semester,
        courses:
            courses.map((course) => course.toJson()).toList(growable: false),
        baseCourses:
            baseBlocks.map((course) => course.toJson()).toList(growable: false),
        manualCourses: manualBlocks
            .map((course) => course.toJson())
            .toList(growable: false),
      );
      return _isCurrentOperation(context);
    } catch (error) {
      debugPrint('保存加密课程失败: ${error.runtimeType}');
      return false;
    }
  }

  List<CourseBlock> _courseModelsToBlocks(List<Course> courses) {
    final blocks = <CourseBlock>[];
    for (final course in courses) {
      for (final meeting in course.meetings) {
        blocks.add(CourseBlock(
          id: meeting.sourceCourseId ??
              (course.source == CourseSource.manual
                  ? -(course.courseKey.hashCode.abs() + 1)
                  : deterministicCourseId(
                      courseCode: course.courseCode ?? '',
                      name: course.name,
                      teacher: meeting.teacher ?? course.teacher ?? '',
                      location: meeting.room ?? '',
                      weekday: meeting.weekday,
                      startSection: meeting.startSection,
                      endSection: meeting.endSection,
                      weeks: meeting.weeks,
                    )),
          courseCode: course.courseCode ?? '',
          name: course.name,
          teacher: meeting.teacher ?? course.teacher,
          location: meeting.room,
          color: course.color,
          weekday: meeting.weekday,
          startSection: meeting.startSection,
          endSection: meeting.endSection,
          weeks: meeting.weeks.toList()..sort(),
          note: meeting.note,
          periodOrder: meeting.periodOrder,
          periodLabel: meeting.periodLabel,
          periodLabels: meeting.periodLabels,
          courseKey: course.courseKey,
          meetingKey: meeting.meetingKey,
          teachingClassId: course.teachingClassId,
          source: course.source.name,
        ));
      }
    }
    return blocks;
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

  Future<bool> _saveOperationSelectedTerm(
    _ScheduleOperationContext context,
    CourseTerm term,
  ) async {
    final store = await _resolveOperationStore(context);
    if (store == null) return false;
    try {
      await store.writeSelectedTerm(term.toJson());
      return _isCurrentOperation(context);
    } catch (error) {
      debugPrint('保存加密选中学期失败: ${error.runtimeType}');
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
      _sourceTrustKnown = true;
      _legacyCacheRequiresResync = false;
      return false;
    }
    final operation = _captureOperationContext();
    final snapshot =
        operation == null ? null : await _loadOperationSnapshot(operation);
    if (operation == null || !_isCurrentOperation(operation)) return false;
    final coalesced = _coalesceGraduateCourses(cached);
    final termId = currentTerm.id;
    _hiddenCourseIds = snapshot?.hiddenCourseIds.toSet() ?? <int>{};
    final sourceRestored = _restoreSourceModels(snapshot);
    _overrides = await _overrideRepository.loadOverrides(
      semesterId: termId,
      accountId: _sourceAccountId,
    );
    if (!_isCurrentOperation(operation)) return false;
    if (sourceRestored) {
      _syncResolvedSchedule();
    } else {
      _courses = coalesced;
      _buildGrid();
      _errorMessage = '旧版课表缺少原始快照，请重新同步教务后再恢复调课';
    }
    if (sourceRestored && _courses.length != cached.length) {
      await _saveToCache(_courses);
    }
    _isLoading = false;
    if (sourceRestored) _errorMessage = null;
    notifyListeners();
    return true;
  }

  bool _restoreSourceModels(ScheduleTermSnapshot? snapshot) {
    final base = snapshot?.baseCourses ?? const <Map<String, dynamic>>[];
    final manual = snapshot?.manualCourses ?? const <Map<String, dynamic>>[];
    if (snapshot?.sourceSnapshotPresent == true) {
      _sourceTrustKnown = true;
      _legacyCacheRequiresResync = false;
      _baseSchedule = _convertToCourses(
        base.map(CourseBlock.fromJson).toList(growable: false),
        currentTerm.id,
      );
      _manualCourses = _convertToCourses(
        manual.map(CourseBlock.fromJson).toList(growable: false),
        currentTerm.id,
      ).map((course) => course.copyWith(source: CourseSource.manual)).toList();
      return true;
    }
    _baseSchedule = [];
    _manualCourses = [];
    _sourceTrustKnown = true;
    _legacyCacheRequiresResync = true;
    return false;
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
    final hiddenCourseIdsBeforeMigration = Set<int>.of(_hiddenCourseIds);

    final customCourses = _courses.where((c) => c.id < 0).toList();
    final fetchedCourses = <CourseBlock>[];
    int importedCount = 0;

    for (final rawCourse in rawCourses) {
      try {
        final parsed = _courseFromFetchedMap(rawCourse);
        fetchedCourses.add(parsed);
      } catch (e) {
        debugPrint('解析课程失败: ${e.runtimeType}');
      }
    }
    final parsedCourses = <CourseBlock>[...customCourses];
    for (final course in _coalesceGraduateCourses(fetchedCourses)) {
      if (_isCourseHidden(course)) continue;
      parsedCourses.add(course);
      importedCount++;
    }

    if (!_sameCourseIdSet(
      hiddenCourseIdsBeforeMigration,
      _hiddenCourseIds,
    )) {
      await _saveOperationHiddenCourses(operation, _hiddenCourseIds);
    }

    debugPrint(
      'Schedule applyFetchedCourses done: '
      'imported=$importedCount, total=${parsedCourses.length}, '
      'cache namespace updated',
    );

    final termId = currentTerm.id;
    _overrides = await _overrideRepository.loadOverrides(
      semesterId: termId,
      accountId: _sourceAccountId,
    );
    final newEduCourses = _convertToCourses(
      _coalesceGraduateCourses(fetchedCourses)
          .where((course) => !_isCourseHidden(course))
          .toList(growable: false),
      termId,
    );
    final reconcileResult = _meetingReconciler.reconcile(
      oldBaseSchedule: _baseSchedule,
      newEduCourses: newEduCourses,
      existingOverrides: _overrides,
      semesterId: termId,
    );
    _baseSchedule = reconcileResult.reconciledCourses;
    _overrides = reconcileResult.updatedOverrides;
    await _overrideRepository.saveOverrides(
      semesterId: termId,
      overrides: _overrides,
      accountId: _sourceAccountId,
    );

    _populateManualCoursesFromBlocks(customCourses);
    _syncResolvedSchedule();
    _legacyCacheRequiresResync = false;
    _sourceTrustKnown = true;

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

  static Map<String, dynamic> _rawCourseToFetchedMap(RawCourse course) {
    final hasProviderPeriod = course.periodOrder != null ||
        (course.periodLabel?.trim().isNotEmpty ?? false);
    late final int startSection;
    late final int endSection;
    if (hasProviderPeriod) {
      final periodOrder = course.periodOrder;
      final periodLabel = course.periodLabel?.trim();
      if (periodOrder == null ||
          periodOrder < 0 ||
          periodLabel == null ||
          periodLabel.isEmpty) {
        throw const ProtocolChangedException(message: '本机课表记录缺少研究生节次元数据');
      }
      // 网格只需要稳定行序；研究生原标签不具备本科数字节次语义。
      startSection = periodOrder + 1;
      endSection = startSection;
    } else {
      final sections = _parseSectionRange(
        course.section,
        message: '本机课表记录缺少有效节次',
      );
      startSection = sections.start;
      endSection = sections.end;
    }
    final weekday = int.tryParse(course.weekDay.trim());
    if (weekday == null || weekday < 1 || weekday > 7) {
      throw const ProtocolChangedException(message: '本机课表记录缺少有效星期');
    }
    final canonical = course.toCanonicalJson();
    final mapped = <String, dynamic>{
      'course_code': canonical['courseCode'] ?? canonical['course_code'] ?? '',
      'name': course.name,
      'teacher': course.teacher,
      'location': course.location,
      'weekday': weekday,
      'start_section': startSection,
      'end_section': endSection,
      'weekExpression': canonical['weekExpression'] ?? course.weekExpression,
      'weeks': canonical['weeks'] ?? const <int>[],
    };
    if (hasProviderPeriod) {
      mapped['period_order'] = course.periodOrder;
      mapped['period_label'] = course.periodLabel!.trim();
      mapped['period_labels'] = <String>[course.periodLabel!.trim()];
    }
    return mapped;
  }

  CourseBlock _courseFromFetchedMap(Map<String, dynamic> map) {
    final name = _firstString(map, [
      'name',
      'course_name',
      'courseName',
      'kcmc',
      'title',
    ]);
    final courseCode = _firstString(map, [
      'course_code',
      'courseCode',
      'course_id',
      'courseId',
      'class_id',
      'classId',
      'jxb_id',
    ]);

    final time = _requiredInt(
      map,
      [
        'time',
        'start_time',
        'startSection',
        'start_section',
        'jc_start',
      ],
      message: '课表记录缺少开始节次',
    );

    final endTime = _requiredInt(
      map,
      [
        'end_time',
        'endSection',
        'end_section',
        'jc_end',
      ],
      message: '课表记录缺少结束节次',
      fallback: time,
    );

    final periodOrder = _optionalInt(map, [
      'period_order',
      'periodOrder',
    ]);
    final periodLabel = _firstString(map, [
      'period_label',
      'periodLabel',
    ]);
    final periodLabels = _stringList(
      map['period_labels'] ?? map['periodLabels'],
      fallback: periodLabel,
    );
    final hasProviderPeriod = periodOrder != null || periodLabel.isNotEmpty;
    if (hasProviderPeriod &&
        (periodOrder == null || periodOrder < 0 || periodLabel.isEmpty)) {
      throw const ProtocolChangedException(message: '课表记录的研究生节次元数据无效');
    }

    final weekday = _requiredInt(
      map,
      [
        'week_day',
        'weekday',
        'dayOfWeek',
        'day_of_week',
        'xqj',
      ],
      message: '课表记录缺少有效星期',
    );
    if (time < 1 || endTime < time || weekday < 1 || weekday > 7) {
      throw const ProtocolChangedException(message: '课表记录的星期或节次无效');
    }

    final teacher = _firstString(map, [
      'teacher',
      'teacher_name',
      'teacherName',
      'jsxm',
    ]);

    final loc = _firstString(map, ['location', 'classroom', 'room', 'jxdd']);

    final weeks = _parseWeeks(map['weeks'] ?? map['week_list'] ?? map['zcd']);

    final id = deterministicCourseId(
      courseCode: courseCode,
      name: name,
      teacher: teacher,
      location: loc,
      weekday: weekday,
      startSection: time,
      endSection: endTime,
      weeks: weeks,
    );

    return CourseBlock(
      id: id,
      courseCode: courseCode,
      name: name,
      teacher: teacher,
      location: loc,
      color: _colorPool[deterministicCourseColorIndex(name, _colorPool.length)],
      weekday: weekday,
      startSection: time,
      endSection: endTime,
      weeks: weeks,
      periodOrder: periodOrder,
      periodLabel: periodLabel.isEmpty ? null : periodLabel,
      periodLabels: periodLabels,
    );
  }

  /// 将研究生课表中同一次上课的相邻原始行归并为一个课程块。
  ///
  /// 学校按单个时段返回数据，但业务侧的课程提醒、冲突判断和各类展示都应
  /// 共享同一个跨节课程语义，因此归并必须发生在进入 `_courses` 之前。
  List<CourseBlock> _coalesceGraduateCourses(
    Iterable<CourseBlock> courses,
  ) {
    final source = courses.toList(growable: false);
    final pairs = <int, int>{};
    final pairedSeconds = <int>{};

    for (var firstIndex = 0; firstIndex < source.length; firstIndex++) {
      final first = source[firstIndex];
      if (first.periodOrder == null || first.periodLabels.length != 1) {
        continue;
      }

      for (var secondIndex = 0; secondIndex < source.length; secondIndex++) {
        if (secondIndex == firstIndex || pairedSeconds.contains(secondIndex)) {
          continue;
        }
        final second = source[secondIndex];
        if (_canMergeGraduatePair(first, second)) {
          pairs[firstIndex] = secondIndex;
          pairedSeconds.add(secondIndex);
          break;
        }
      }
    }

    final result = <CourseBlock>[];
    for (var index = 0; index < source.length; index++) {
      if (pairedSeconds.contains(index)) continue;
      final secondIndex = pairs[index];
      if (secondIndex == null) {
        result.add(source[index]);
        continue;
      }
      result.add(_mergeGraduatePair(source[index], source[secondIndex]));
    }
    return result;
  }

  bool _canMergeGraduatePair(CourseBlock first, CourseBlock second) {
    if (first.periodOrder == null ||
        second.periodOrder == null ||
        first.periodLabels.length != 1 ||
        second.periodLabels.length != 1 ||
        first.span != 1 ||
        second.span != 1 ||
        second.periodOrder != first.periodOrder! + 1 ||
        second.startSection != first.startSection + 1) {
      return false;
    }
    if (first.weekday != second.weekday ||
        first.name.trim() != second.name.trim() ||
        _normalized(first.teacher) != _normalized(second.teacher) ||
        _normalized(first.location) != _normalized(second.location) ||
        !listEquals(first.weeks, second.weeks)) {
      return false;
    }

    final firstPeriod = _parseGraduatePeriodLabel(first.periodLabels.single);
    final secondPeriod = _parseGraduatePeriodLabel(second.periodLabels.single);
    if (firstPeriod == null || secondPeriod == null) return false;
    return firstPeriod.group == secondPeriod.group &&
        firstPeriod.number.isOdd &&
        secondPeriod.number == firstPeriod.number + 1;
  }

  CourseBlock _mergeGraduatePair(CourseBlock first, CourseBlock second) {
    final firstPeriod = _parseGraduatePeriodLabel(first.periodLabels.single)!;
    final secondPeriod = _parseGraduatePeriodLabel(second.periodLabels.single)!;
    final labels = <String>[
      first.periodLabels.single.trim(),
      second.periodLabels.single.trim(),
    ];
    final id = deterministicCourseId(
      courseCode: first.courseCode,
      name: first.name,
      teacher: first.teacher ?? '',
      location: first.location ?? '',
      weekday: first.weekday,
      startSection: first.startSection,
      endSection: second.endSection,
      weeks: first.weeks,
    );

    return CourseBlock(
      id: id,
      courseCode: first.courseCode,
      name: first.name,
      teacher: first.teacher,
      location: first.location,
      color: first.color,
      weekday: first.weekday,
      startSection: first.startSection,
      endSection: second.endSection,
      weeks: first.weeks,
      note: first.note,
      periodOrder: first.periodOrder,
      periodLabel:
          '${firstPeriod.group}${firstPeriod.number}-${secondPeriod.number}',
      periodLabels: labels,
    );
  }

  static ({String group, int number})? _parseGraduatePeriodLabel(
    String label,
  ) {
    final match =
        RegExp(r'^\s*(上午|下午|晚上)\s*(?:第\s*)?(\d+)\s*节?\s*$').firstMatch(label);
    final number = int.tryParse(match?.group(2) ?? '');
    if (match == null || number == null || number < 1) return null;
    return (group: match.group(1)!, number: number);
  }

  static String _normalized(String? value) => value?.trim() ?? '';

  List<String> _stringList(Object? raw, {String fallback = ''}) {
    final values = raw is List
        ? raw
            .map((value) => value.toString().trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    return values.isNotEmpty
        ? values
        : fallback.isEmpty
            ? const <String>[]
            : <String>[fallback];
  }

  int _legacyCourseId(CourseBlock course) {
    final raw =
        '${course.name}-${course.weekday}-${course.startSection}-${course.endSection}-${course.teacher ?? ''}-${course.location ?? ''}';
    var id = raw.hashCode.abs();
    if (id == 0) id = 1;
    return id;
  }

  /// 兼容旧版用 String.hashCode 生成的隐藏课程 ID，并在命中时迁移到新 ID。
  bool _isCourseHidden(CourseBlock course) {
    if (_hiddenCourseIds.contains(course.id)) return true;
    final legacyId = _legacyCourseId(course);
    if (legacyId == course.id || !_hiddenCourseIds.remove(legacyId)) {
      return false;
    }
    _hiddenCourseIds.add(course.id);
    return true;
  }

  bool _sameCourseIdSet(Set<int> left, Set<int> right) {
    return left.length == right.length && left.containsAll(right);
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

  int _requiredInt(
    Map<String, dynamic> map,
    List<String> keys, {
    required String message,
    int? fallback,
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
    if (fallback != null) return fallback;
    throw ProtocolChangedException(message: message);
  }

  int? _optionalInt(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  static ({int start, int end}) _parseSectionRange(
    String raw, {
    required String message,
  }) {
    final match = RegExp(
      r'^\s*(\d+)\s*(?:[-~至到—–]\s*(\d+)\s*)?节?\s*$',
    ).firstMatch(raw);
    if (match == null) {
      throw ProtocolChangedException(message: message);
    }
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2) ?? match.group(1)!);
    if (start == null || end == null || start < 1 || end < start) {
      throw ProtocolChangedException(message: message);
    }
    return (start: start, end: end);
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
      final weeks = WeekParser.parse(raw).weeks.toList()..sort();
      if (raw.trim().isNotEmpty && weeks.isEmpty) {
        throw const ProtocolChangedException(message: '课表记录周次格式无法识别');
      }
      return weeks;
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
      final cachedRaw =
          snapshot?.courses.map(CourseBlock.fromJson).toList(growable: false);
      final cached =
          cachedRaw == null ? null : _coalesceGraduateCourses(cachedRaw);
      if (cached != null && cached.isNotEmpty) {
        _hiddenCourseIds = snapshot?.hiddenCourseIds.toSet() ?? <int>{};
        final sourceRestored = _restoreSourceModels(snapshot);
        _overrides = await _overrideRepository.loadOverrides(
          semesterId: currentTerm.id,
          accountId: _sourceAccountId,
        );
        if (!_isCurrentOperation(operation)) return;
        if (sourceRestored) {
          _syncResolvedSchedule();
          _errorMessage = null;
        } else {
          _courses = cached;
          _buildGrid();
          _errorMessage = '旧版课表缺少原始快照，请重新同步教务后再恢复调课';
        }
        if (sourceRestored &&
            cachedRaw != null &&
            cached.length != cachedRaw.length) {
          await _saveOperationCourses(operation, _courses);
          if (!_isCurrentOperation(operation)) return;
        }
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
    final hiddenCourseIdsBeforeMigration = Set<int>.of(_hiddenCourseIds);

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

    // 原始课表只通过本机教务数据源按需获取。成功后仍写入当前
    // 账号和来源账号隔离的本地加密保险箱，不创建服务端课程副本。
    final localController = _academicSessionController;
    // 来源选择是显式契约：本机来源即使尚未登录，也必须停在本机登录态，
    // 不能因为旧服务端存在绑定信息而静默改走服务端教务接口。
    final localSessionActive = _academicSessionController != null ||
        _academicRepository?.sourceKind == AcademicSourceKind.local;
    if (localSessionActive) {
      if (localController == null) {
        if (!_isCurrentOperation(operation)) return;
        _errorMessage = '本机教务会话控制器未就绪';
      } else {
        try {
          final fetched = await localController.loadCourses(
            year: operation.year,
            semester: operation.semester,
            providerTermId: operation.providerTermId,
          );
          if (fetched == null) {
            if (!_isCurrentOperation(operation)) return;
            _errorMessage = localController.failure?.message ?? '获取课表失败';
          } else {
            if (!_isCurrentOperation(operation)) return;
            final rawCourses = fetched.courses
                .map(_rawCourseToFetchedMap)
                .toList(growable: false);
            if (rawCourses.isEmpty &&
                backupCourses.isNotEmpty &&
                !isManualRefresh) {
              debugPrint('教务系统返回空课表，保留当前本地课程');
              _courses = backupCourses;
              _buildGrid();
            } else {
              final parsedCourses = <CourseBlock>[];
              for (final rawCourse in rawCourses) {
                parsedCourses.add(_courseFromFetchedMap(rawCourse));
              }
              final fetchedCourses = <CourseBlock>[];
              for (final course in _coalesceGraduateCourses(parsedCourses)) {
                if (!_isCourseHidden(course)) fetchedCourses.add(course);
              }
              _courses = fetchedCourses;
              if (!_sameCourseIdSet(
                hiddenCourseIdsBeforeMigration,
                _hiddenCourseIds,
              )) {
                await _saveOperationHiddenCourses(
                  operation,
                  _hiddenCourseIds,
                );
              }
              _buildGrid();
              networkSuccess = true;
            }
            debugPrint('本机直连教务拉取课程: count=${_courses.length}');
          }
        } on AcademicFailure catch (error) {
          if (!_isCurrentOperation(operation)) return;
          _errorMessage = error.message;
        } catch (error) {
          if (!_isCurrentOperation(operation)) return;
          _errorMessage = '解析课表数据失败';
          debugPrint('解析本机教务课表失败: ${error.runtimeType}');
        }
      }
    }
    if (!_isCurrentOperation(operation)) return;

    // 本机教务读取成功后，保存或清理缓存
    if (networkSuccess) {
      // 恢复所有本地的自定义课程 (包括 AI 导入的课程，其 id 均为负数)
      final customCourses = backupCourses.where((c) => c.id < 0).toList();
      if (customCourses.isNotEmpty) {
        _courses.addAll(customCourses);
        _buildGrid();
      }

      // 网络结果落盘前重建原始/自定义模型；缓存中的 courses 仅作为展示结果。
      _populateSchedulesFromBlocks(_coalesceGraduateCourses(_courses));
      _overrides = await _overrideRepository.loadOverrides(
        semesterId: currentTerm.id,
        accountId: _sourceAccountId,
      );
      _syncResolvedSchedule();

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
    debugPrint('课表本机读取完成: count=${_courses.length}');
  }

  /// 同步课程数据到桌面小部件（非阻塞）
  void _syncWidget() {
    if (_userId == null) return;
    if (!PlatformCapabilities.current.supportsNativeWidget) return;
    // 使用 microtask 避免阻塞 UI
    Future.microtask(() => HomeWidgetService.syncCourseData(this));
  }

  /// 重新解析课表并更新内存中的 _courses 与桌面小部件
  void _syncResolvedSchedule() {
    final termId = currentTerm.id;
    final visibleBaseSchedule = _baseSchedule
        .map((course) {
          final meetings = course.meetings
              .where((meeting) =>
                  meeting.sourceCourseId == null ||
                  !_hiddenCourseIds.contains(meeting.sourceCourseId))
              .toList(growable: false);
          return meetings.isEmpty ? null : course.copyWith(meetings: meetings);
        })
        .whereType<Course>()
        .toList(growable: false);
    final resolved = _scheduleResolver.resolve(
      baseSchedule: visibleBaseSchedule,
      overrides: _overrides,
      manualCourses: _manualCourses,
      semesterId: termId,
      totalTeachingWeeks: currentTerm.maxWeek,
    );
    _resolvedMeetings = resolved;

    _courses = resolved.map((r) {
      final isManual = r.source == CourseSource.manual;
      final int id = isManual
          ? -(r.courseKey.hashCode.abs() % 100000000 + 1000)
          : (r.sourceCourseId != null && r.sourceCourseId != 0
              ? r.sourceCourseId!
              : deterministicCourseId(
                  courseCode: r.courseCode ?? '',
                  name: r.courseName,
                  teacher: r.teacher,
                  location: r.room,
                  weekday: r.weekday,
                  startSection: r.startSection,
                  endSection: r.endSection,
                  weeks: r.weeks,
                ));

      return CourseBlock(
        id: id,
        courseCode: r.courseCode ?? '',
        name: r.courseName,
        teacher: r.teacher,
        location: r.room,
        color: r.color,
        weekday: r.weekday,
        startSection: r.startSection,
        endSection: r.endSection,
        weeks: r.weeks.toList()..sort(),
        note: r.note,
        periodOrder: r.periodOrder,
        periodLabel: r.periodLabel,
        periodLabels: r.periodLabels,
        isOverridden: r.isOverridden,
        overrideId: r.overrideId,
        conflictWeeks: r.conflictWeeks,
        hasConflict: r.hasConflict,
        courseKey: r.courseKey,
        meetingKey: r.meetingKey,
        teachingClassId: r.teachingClassId,
        source: r.source.name,
      );
    }).toList();

    _buildGrid();
    _syncWidget();
  }

  void _populateSchedulesFromBlocks(List<CourseBlock> blocks) {
    final termId = currentTerm.id;
    final eduBlocks = blocks.where((b) => b.id > 0).toList();
    final manualBlocks = blocks.where((b) => b.id < 0).toList();

    final eduGrouped = <String, List<CourseBlock>>{};
    for (final b in eduBlocks) {
      final cKey = b.courseKey ??
          'edu:$termId:${b.courseCode.isNotEmpty ? b.courseCode : b.name}';
      eduGrouped.putIfAbsent(cKey, () => []).add(b);
    }

    _baseSchedule = eduGrouped.entries.map((entry) {
      final first = entry.value.first;
      final meetings = entry.value.map((b) {
        final sortedWks = b.weeks.toList()..sort();
        final mKey = b.meetingKey ??
            '${entry.key}:m:w${b.weekday}:s${b.startSection}-${b.endSection}:wks[${sortedWks.join(',')}]';
        return Meeting(
          meetingKey: mKey,
          weekday: b.weekday,
          startSection: b.startSection,
          endSection: b.endSection,
          weeks: b.weeks.toSet(),
          room: b.location,
          teacher: b.teacher,
          note: b.note,
          periodOrder: b.periodOrder,
          periodLabel: b.periodLabel,
          periodLabels: b.periodLabels,
          sourceCourseId: b.id,
        );
      }).toList();

      return Course(
        courseKey: entry.key,
        semesterId: termId,
        source: CourseSource.edu,
        name: first.name,
        courseCode: first.courseCode,
        teachingClassId: first.teachingClassId,
        teacher: first.teacher,
        color: first.color,
        meetings: meetings,
      );
    }).toList();

    _populateManualCoursesFromBlocks(manualBlocks);
  }

  void _populateManualCoursesFromBlocks(List<CourseBlock> manualBlocks) {
    final termId = currentTerm.id;
    final manualGrouped = <String, List<CourseBlock>>{};
    for (final b in manualBlocks) {
      final cKey = b.courseKey ?? 'manual:$termId:${b.name}';
      manualGrouped.putIfAbsent(cKey, () => []).add(b);
    }

    _manualCourses = manualGrouped.entries.map((entry) {
      final first = entry.value.first;
      final meetings = entry.value.map((b) {
        final sortedWks = b.weeks.toList()..sort();
        final mKey = b.meetingKey ??
            '${entry.key}:m:w${b.weekday}:s${b.startSection}-${b.endSection}:wks[${sortedWks.join(',')}]';
        return Meeting(
          meetingKey: mKey,
          weekday: b.weekday,
          startSection: b.startSection,
          endSection: b.endSection,
          weeks: b.weeks.toSet(),
          room: b.location,
          teacher: b.teacher,
          note: b.note,
          periodOrder: b.periodOrder,
          periodLabel: b.periodLabel,
          periodLabels: b.periodLabels,
          sourceCourseId: b.id,
        );
      }).toList();

      return Course(
        courseKey: entry.key,
        semesterId: termId,
        source: CourseSource.manual,
        name: first.name,
        teacher: first.teacher,
        color: first.color,
        meetings: meetings,
      );
    }).toList();
  }

  List<Course> _convertToCourses(List<CourseBlock> blocks, String semesterId) {
    final grouped = <String, List<CourseBlock>>{};
    for (final b in blocks) {
      final cKey = b.courseKey ??
          'edu:$semesterId:${b.courseCode.isNotEmpty ? b.courseCode : b.name}';
      grouped.putIfAbsent(cKey, () => []).add(b);
    }

    return grouped.entries.map((entry) {
      final first = entry.value.first;
      final meetings = entry.value.map((b) {
        final sortedWks = b.weeks.toList()..sort();
        final mKey = b.meetingKey ??
            '${entry.key}:m:w${b.weekday}:s${b.startSection}-${b.endSection}:wks[${sortedWks.join(',')}]';
        return Meeting(
          meetingKey: mKey,
          weekday: b.weekday,
          startSection: b.startSection,
          endSection: b.endSection,
          weeks: b.weeks.toSet(),
          room: b.location,
          teacher: b.teacher,
          note: b.note,
          periodOrder: b.periodOrder,
          periodLabel: b.periodLabel,
          periodLabels: b.periodLabels,
          sourceCourseId: b.id,
        );
      }).toList();

      return Course(
        courseKey: entry.key,
        semesterId: semesterId,
        source: CourseSource.edu,
        name: first.name,
        courseCode: first.courseCode,
        teachingClassId: first.teachingClassId,
        teacher: first.teacher,
        color: first.color,
        meetings: meetings,
      );
    }).toList();
  }

  /// 创建或更新时间调整规则 (Section 18 - 20)
  Future<ScheduleOverride> createRescheduleOverride({
    required String courseKey,
    required String meetingKey,
    required Set<int> affectedWeeks,
    required int toWeekday,
    required int toStartSection,
    required int toEndSection,
    String? toRoom,
    required String sourceSnapshotHash,
    int? fromWeekday,
    int? fromStartSection,
    int? fromEndSection,
    String? fromRoom,
    bool allowConflict = false,
    String? overrideId,
  }) async {
    await _ensureTrustedSourceForMutation();
    final effectiveId =
        overrideId ?? 'ov_${DateTime.now().millisecondsSinceEpoch}';
    var status = ScheduleOverrideStatus.active;

    final conflictCheck = _conflictService.check(
      currentResolved: _resolvedMeetings,
      targetCourseKey: courseKey,
      targetMeetingKey: meetingKey,
      targetWeekday: toWeekday,
      targetStartSection: toStartSection,
      targetEndSection: toEndSection,
      targetWeeks: affectedWeeks,
      editingOverrideId: overrideId,
    );
    if (conflictCheck.hasConflict) {
      if (!allowConflict) {
        throw StateError('存在课程时间冲突，请确认或重新选择时间');
      }
      status = ScheduleOverrideStatus.conflicted;
    }

    final override = ScheduleOverride(
      id: effectiveId,
      semesterId: currentTerm.id,
      courseKey: courseKey,
      meetingKey: meetingKey,
      type: ScheduleOverrideType.reschedule,
      status: status,
      affectedWeeks: affectedWeeks,
      toWeekday: toWeekday,
      toStartSection: toStartSection,
      toEndSection: toEndSection,
      toRoom: toRoom,
      sourceSnapshotHash: sourceSnapshotHash,
      fromWeekday: fromWeekday,
      fromStartSection: fromStartSection,
      fromEndSection: fromEndSection,
      fromRoom: fromRoom,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final persisted = await _overrideRepository.upsertOverride(
      override: override,
      accountId: _sourceAccountId,
    );
    if (!persisted) {
      throw StateError('调课规则保存失败，请稍后重试');
    }
    _overrides = await _overrideRepository.loadOverrides(
      semesterId: currentTerm.id,
      accountId: _sourceAccountId,
    );
    _syncResolvedSchedule();
    await _persistResolvedScheduleOrThrow();
    notifyListeners();
    return override;
  }

  /// 创建或更新教室调整规则 (Section 22)
  Future<ScheduleOverride> createChangeRoomOverride({
    required String courseKey,
    required String meetingKey,
    required Set<int> affectedWeeks,
    required String toRoom,
    required String sourceSnapshotHash,
    String? fromRoom,
    String? overrideId,
  }) async {
    await _ensureTrustedSourceForMutation();
    final effectiveId =
        overrideId ?? 'ov_${DateTime.now().millisecondsSinceEpoch}';
    final override = ScheduleOverride(
      id: effectiveId,
      semesterId: currentTerm.id,
      courseKey: courseKey,
      meetingKey: meetingKey,
      type: ScheduleOverrideType.changeRoom,
      status: ScheduleOverrideStatus.active,
      affectedWeeks: affectedWeeks,
      toRoom: toRoom,
      sourceSnapshotHash: sourceSnapshotHash,
      fromRoom: fromRoom,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final persisted = await _overrideRepository.upsertOverride(
      override: override,
      accountId: _sourceAccountId,
    );
    if (!persisted) {
      throw StateError('教室调整保存失败，请稍后重试');
    }
    _overrides = await _overrideRepository.loadOverrides(
      semesterId: currentTerm.id,
      accountId: _sourceAccountId,
    );
    _syncResolvedSchedule();
    await _persistResolvedScheduleOrThrow();
    notifyListeners();
    return override;
  }

  /// 更新已有调整规则 (Section 26)
  Future<ScheduleOverride> updateExistingOverride({
    required ScheduleOverride updated,
    bool allowConflict = false,
  }) async {
    await _ensureTrustedSourceForMutation();
    final persisted = await _overrideRepository.upsertOverride(
      override: updated,
      accountId: _sourceAccountId,
    );
    if (!persisted) {
      throw StateError('调课规则保存失败，请稍后重试');
    }
    _overrides = await _overrideRepository.loadOverrides(
      semesterId: currentTerm.id,
      accountId: _sourceAccountId,
    );
    _syncResolvedSchedule();
    await _persistResolvedScheduleOrThrow();
    notifyListeners();
    return updated;
  }

  /// 恢复教务原课 (Section 25: 删除 Override，重跑 Resolver)
  Future<void> restoreBaseMeeting(String overrideId) async {
    await _ensureTrustedSourceForMutation();
    final persisted = await _overrideRepository.deleteOverride(
      overrideId: overrideId,
      semesterId: currentTerm.id,
      accountId: _sourceAccountId,
    );
    if (!persisted) {
      throw StateError('恢复原安排失败，请稍后重试');
    }
    _overrides = await _overrideRepository.loadOverrides(
      semesterId: currentTerm.id,
      accountId: _sourceAccountId,
    );
    _syncResolvedSchedule();
    await _persistResolvedScheduleOrThrow();
    notifyListeners();
  }

  /// 重新确认变更后的课表调整 (Section 10 & 17)
  Future<void> confirmNeedsReviewOverride(String overrideId) async {
    final idx = _overrides.indexWhere((o) => o.id == overrideId);
    if (idx < 0) return;
    final current = _overrides[idx];
    final courseMatches =
        _baseSchedule.where((c) => c.courseKey == current.courseKey);
    final course = courseMatches.isNotEmpty ? courseMatches.first : null;
    final meetingMatches =
        course?.meetings.where((m) => m.meetingKey == current.meetingKey);
    final meeting = (meetingMatches != null && meetingMatches.isNotEmpty)
        ? meetingMatches.first
        : null;
    final newHash =
        meeting?.computeSnapshotHash() ?? current.sourceSnapshotHash;

    final updated = current.copyWith(
      status: ScheduleOverrideStatus.active,
      sourceSnapshotHash: newHash,
      updatedAt: DateTime.now(),
    );
    await updateExistingOverride(updated: updated);
  }

  /// 保存课程到当前账号和来源账号绑定的 AES-GCM 保险箱。
  Future<bool> _saveToCache(List<CourseBlock> courses) async {
    final operation = _captureOperationContext();
    if (operation == null) return false;
    return _saveOperationCourses(operation, courses);
  }

  Future<void> _persistResolvedScheduleOrThrow() async {
    if (_userId != null && !await _saveToCache(_courses)) {
      throw StateError('课表保存失败，请稍后重试');
    }
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
      if (_sessionPhase == ScheduleSessionPhase.restoringCache) rethrow;
      return null;
    }
  }

  /// 清除当前学期的加密课程，但保留同学期的用户存档和隐藏状态。
  Future<void> clearCache() async {
    final operation = _captureOperationContext();
    if (operation == null) return;
    await _clearOperationCourses(operation);
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
    _syncWidget();
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
    _syncWidget();
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
    await _ensureTrustedSourceForMutation();
    final weeks = List.generate(endWeek - startWeek + 1, (i) => startWeek + i);
    final colorIdx = deterministicCourseColorIndex(name, _colorPool.length);
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
      courseKey: 'manual:${currentTerm.id}:$newId',
      meetingKey: 'manual:${currentTerm.id}:$newId:meeting',
    );

    _courses.insert(0, course);
    _populateManualCoursesFromBlocks(_courses.where((c) => c.id < 0).toList());
    _syncResolvedSchedule();

    await _persistResolvedScheduleOrThrow();

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
    await _ensureTrustedSourceForMutation();
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
      periodOrder: oldCourse.periodOrder,
      periodLabel: oldCourse.periodLabel,
      periodLabels: oldCourse.periodLabels,
      courseKey: oldCourse.courseKey,
      meetingKey: oldCourse.meetingKey,
    );

    _courses[idx] = course;
    _populateManualCoursesFromBlocks(_courses.where((c) => c.id < 0).toList());
    _syncResolvedSchedule();

    await _persistResolvedScheduleOrThrow();

    notifyListeners();
    return course;
  }

  /// 删除课程（支持自定义课程和服务器课程）
  Future<void> removeCustomCourse(int courseId) async {
    await _ensureTrustedSourceForMutation();
    _courses.removeWhere((c) => c.id == courseId);
    if (courseId > 0) {
      _hiddenCourseIds.add(courseId);
      await _saveHiddenCourses();
    }
    _populateManualCoursesFromBlocks(_courses.where((c) => c.id < 0).toList());
    _syncResolvedSchedule();
    await _persistResolvedScheduleOrThrow();
    notifyListeners();
  }

  Future<void> _ensureTrustedSourceForMutation() async {
    await _sessionRestoreFuture;
    if (!_sourceTrustKnown || _legacyCacheRequiresResync) {
      throw StateError('旧版课表缺少原始快照，请先重新同步教务后再修改课表');
    }
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
    final operation = _captureOperationContext(term);
    if (operation == null ||
        operation.store == null ||
        !await _saveOperationSelectedTerm(operation, term)) {
      return false;
    }
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
    if (operation == null ||
        operation.store == null ||
        !await _saveOperationSelectedTerm(operation, term)) {
      return 0;
    }

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
        .toList();

    await _clearOperationActiveArchive(operation);
    if (!_isCurrentOperation(operation)) return 0;

    _courses = _coalesceGraduateCourses(
      snapshot?.courses.map(CourseBlock.fromJson) ?? const <CourseBlock>[],
    );
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
        .toList();
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
    final courses = _coalesceGraduateCourses(
      list.map((e) => CourseBlock.fromJson(e as Map<String, dynamic>)),
    );
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

    _courses = _coalesceGraduateCourses(
      archive.courses.map(CourseBlock.fromJson),
    );
    // 存档是完整可恢复状态：载入后同步替换来源模型并清除当前学期规则，
    // 避免下一次重算又被载入前的底层课表覆盖。
    _populateSchedulesFromBlocks(_courses);
    if (!await _overrideRepository.clearOverrides(
      semesterId: currentTerm.id,
      accountId: _sourceAccountId,
    )) {
      throw StateError('载入存档失败：无法清除旧调课规则');
    }
    if (!_isCurrentOperation(operation)) return;
    _overrides = [];
    _hiddenCourseIds = {};
    _syncResolvedSchedule();
    if (!await _saveOperationHiddenCourses(operation, _hiddenCourseIds) ||
        !await _saveOperationCourses(operation, _courses)) {
      throw StateError('载入存档失败：无法保存完整课表状态');
    }
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
