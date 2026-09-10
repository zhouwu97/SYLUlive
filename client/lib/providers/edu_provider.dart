import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import '../features/campus_data/storage/academic_cache_store.dart';
import '../features/campus_data/storage/account_scoped_snapshot_store.dart';
import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/storage/academic_persistence_gate.dart';
import '../features/academic/storage/academic_storage_preferences.dart';
import '../features/academic/data/mapper/raw_grade_mapper.dart';
import '../features/academic/domain/academic_failure.dart';
import '../features/academic/domain/academic_repository.dart';
import '../features/academic/domain/academic_provider.dart';
import '../features/academic/application/academic_identity_lifecycle_coordinator.dart';
import '../features/academic/storage/academic_connection_store.dart';
import '../models/edu_academic_situation.dart';
import '../models/edu_credit_requirement.dart';
import '../models/edu_grade.dart';
import '../utils/edu_semester_utils.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

/// 操作结果，包含成功状态和错误信息
class OperationResult<T> {
  final bool success;
  final T? data;
  final String? errorMessage;
  final String? errorCode;

  const OperationResult({
    required this.success,
    this.data,
    this.errorMessage,
    this.errorCode,
  });

  factory OperationResult.ok(T data) =>
      OperationResult(success: true, data: data);

  factory OperationResult.fail(String message, {String? errorCode}) =>
      OperationResult(
        success: false,
        errorMessage: message,
        errorCode: errorCode,
      );
}

/// 成绩缓存条目
class GradeCacheEntry {
  final List<EduGrade> grades;
  final DateTime updatedAt;

  const GradeCacheEntry({required this.grades, required this.updatedAt});
}

/// 学业情况缓存条目
class AcademicSituationCacheEntry {
  final EduAcademicSituation data;
  final DateTime updatedAt;

  const AcademicSituationCacheEntry({
    required this.data,
    required this.updatedAt,
  });
}

/// 学分要求缓存条目
class CreditRequirementCacheEntry {
  final EduCreditRequirementOverview data;
  final DateTime updatedAt;

  const CreditRequirementCacheEntry({
    required this.data,
    required this.updatedAt,
  });
}

class EduProvider extends ChangeNotifier {
  final Dio _dio;
  final AccountScopedSnapshotStore Function(String appUserId)?
      _snapshotStoreBuilder;

  String? _userId;
  bool _isBound = false;
  bool _isAuthorized = false;
  String _sessionState = 'unbound';
  String _studentId = '';
  String _name = '';
  String _grade = '';
  String _college = '';
  String _major = '';
  bool _isLoading = false;
  bool _statusLoaded = false;
  String? _errorMessage;
  final Map<String, GradeCacheEntry> _gradeCache = {};
  final Map<String, EduGradeDetail> _gradeDetailCache = {};
  final Map<String, AcademicSituationCacheEntry> _academicSituationCache = {};
  final Map<String, CreditRequirementCacheEntry> _creditRequirementCache = {};
  int _statusGeneration = 0;
  bool _eduRequestBusy = false;
  int _foregroundRequests = 0;
  AcademicSessionController? _academicSessionController;
  bool _usingLocalAcademicSession = false;
  Future<void> _persistenceReady = Future<void>.value();
  String _persistenceContextKey = '';

  bool get isBound => _isBound;
  bool get isAuthorized => _isAuthorized;
  String get sessionState => _sessionState;
  String get studentId => _studentId;
  String get name => _name;
  String get grade => _grade;
  String get college => _college;
  String get major => _major;
  bool get isLoading => _isLoading;
  bool get isStatusLoaded => _statusLoaded;
  String? get errorMessage => _errorMessage;
  bool get isUsingLocalAcademicSession => _usingLocalAcademicSession;
  AcademicCapabilities get academicCapabilities =>
      _academicSessionController?.capabilities ??
      const AcademicCapabilities.local();

  /// 当前教务身份的物理缓存命名空间；服务端兼容身份尚未解析时为空，
  /// 由缓存层沿用旧兼容命名空间，解析完成后会随会话状态重新创建。
  String? get academicIdentityNamespace =>
      _academicSessionController?.identity?.storageId;
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

  /// 当前实际请求使用的教务来源。
  ///
  /// 只要主应用注入了会话控制器，就以仓储显式选择的来源为准。来源未
  /// 完成登录时只能返回“未就绪”，不能因为旧服务端仍有绑定状态而偷偷
  /// 改走兼容代理。
  AcademicSourceKind get _activeAcademicSourceKind {
    final controller = _academicSessionController;
    if (controller != null) return controller.sourceKind;
    return AcademicSourceKind.local;
  }

  /// 内存缓存 key：App 用户 + 教务来源 + 来源学号 + 学年学期。
  String _cacheKeyFor(
    String userId,
    String sourceAccountId,
    AcademicSourceKind source,
    String year,
    int semester,
  ) {
    return 'edu_grades_${userId}_${source.name}_'
        '${sourceAccountId}_${year}_$semester';
  }

  String _academicSituationCacheKey(
    String userId,
    String sourceAccountId,
    AcademicSourceKind source,
  ) {
    return 'edu_academic_situation_${userId}_${source.name}_$sourceAccountId';
  }

  String _creditRequirementCacheKey(
    String userId,
    String sourceAccountId,
    AcademicSourceKind source,
  ) {
    return 'edu_credit_requirements_${userId}_${source.name}_$sourceAccountId';
  }

  AcademicCacheStore? _academicCacheStoreFor({
    required String appUserId,
    required String sourceAccountId,
  }) {
    if (appUserId.trim().isEmpty || sourceAccountId.trim().isEmpty) return null;
    return AcademicCacheStore(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
      identityNamespace: academicIdentityNamespace,
      snapshotStore: _snapshotStoreBuilder?.call(appUserId),
      persistenceGate: RegistryAcademicPersistenceGate(appUserId),
    );
  }

  bool _isSameAcademicContext(
    String appUserId,
    String sourceAccountId,
    AcademicSourceKind source,
  ) {
    return _userId == appUserId &&
        _studentId.trim() == sourceAccountId &&
        _activeAcademicSourceKind == source;
  }

  /// 读取内存缓存（同步方法，直接使用当前 _userId，安全）
  GradeCacheEntry? getCachedGrades(String year, int semester) {
    final userId = _userId;
    final sourceAccountId = _studentId.trim();
    if (userId == null || sourceAccountId.isEmpty) return null;
    return _gradeCache[_cacheKeyFor(
      userId,
      sourceAccountId,
      _activeAcademicSourceKind,
      year,
      semester,
    )];
  }

  /// 读取学业情况缓存。
  AcademicSituationCacheEntry? getCachedAcademicSituation() {
    final userId = _userId;
    final sourceAccountId = _studentId.trim();
    if (userId == null || sourceAccountId.isEmpty) {
      return null;
    }
    return _academicSituationCache[_academicSituationCacheKey(
      userId,
      sourceAccountId,
      _activeAcademicSourceKind,
    )];
  }

  /// 读取学分要求缓存。
  CreditRequirementCacheEntry? getCachedCreditRequirements() {
    final userId = _userId;
    final sourceAccountId = _studentId.trim();
    if (userId == null || sourceAccountId.isEmpty) {
      return null;
    }
    return _creditRequirementCache[_creditRequirementCacheKey(
      userId,
      sourceAccountId,
      _activeAcademicSourceKind,
    )];
  }

  /// 清除指定用户的所有成绩缓存
  void clearGradeCacheForUser(String userId) {
    final prefix = 'edu_grades_${userId}_';
    _gradeCache.removeWhere((key, _) => key.startsWith(prefix));
    _gradeDetailCache.removeWhere((key, _) => key.startsWith('$userId|'));
    _academicSituationCache.removeWhere(
      (key, _) => key.startsWith('edu_academic_situation_${userId}_'),
    );
    _creditRequirementCache.removeWhere(
      (key, _) => key.startsWith('edu_credit_requirements_${userId}_'),
    );
  }

  String _gradeDetailCacheKey(EduGrade grade, String year, int semester) {
    final stableId = grade.studentGradeId.isNotEmpty
        ? grade.studentGradeId
        : grade.classId.isNotEmpty
            ? grade.classId
            : grade.name;

    return '${_userId ?? ''}|${_activeAcademicSourceKind.name}|'
        '${_studentId.trim()}|$year|$semester|$stableId';
  }

  Future<T> _runEduRequest<T>(Future<T> Function() task,
      {bool background = false}) async {
    if (!background) _foregroundRequests++;
    while (_eduRequestBusy || background && _foregroundRequests > 0) {
      await Future.delayed(const Duration(milliseconds: 120));
    }
    _eduRequestBusy = true;
    try {
      return await task();
    } finally {
      _eduRequestBusy = false;
      if (!background) _foregroundRequests--;
    }
  }

  EduGradeDetail? getCachedGradeDetail(
      EduGrade grade, String year, int semester) {
    if (_studentId.trim().isEmpty) return null;
    return _gradeDetailCache[_gradeDetailCacheKey(grade, year, semester)];
  }

  EduProvider(
    Dio legacyAuthDio, [
    AccountScopedSnapshotStore Function(String appUserId)? snapshotStoreBuilder,
  ])  : _dio = legacyAuthDio,
        _snapshotStoreBuilder = snapshotStoreBuilder;

  /// 接入由仓储选择来源的教务会话。
  ///
  /// 该 setter 保持独立于构造函数，避免破坏已有测试和旧页面的依赖注入。
  void setAcademicSessionController(AcademicSessionController controller) {
    if (identical(_academicSessionController, controller)) return;
    _academicSessionController?.removeListener(_onAcademicSessionChanged);
    _academicSessionController = controller;
    controller.addListener(_onAcademicSessionChanged);
    _applyAcademicSessionState();
  }

  void _onAcademicSessionChanged() {
    _applyAcademicSessionState();
    final userId = _userId;
    if (userId != null) {
      _setPersistenceReadiness(userId, _studentId.trim());
      final profile = _academicSessionController?.profile;
      final sourceAccountId = _studentId.trim();
      if (profile != null && sourceAccountId.isNotEmpty) {
        unawaited(_persistProfileSnapshot(
          userId: userId,
          sourceAccountId: sourceAccountId,
          profile: profile.toJson(),
        ));
      }
    }
  }

  Future<void> _persistProfileSnapshot({
    required String userId,
    required String sourceAccountId,
    required Map<String, dynamic> profile,
  }) async {
    final identity = _academicSessionController?.identity;
    final generation = _academicSessionController?.contextGeneration;
    final store = _academicCacheStoreFor(
        appUserId: userId, sourceAccountId: sourceAccountId);
    try {
      await _persistenceReady;
      if (_userId != userId ||
          _studentId.trim() != sourceAccountId ||
          identity != _academicSessionController?.identity ||
          generation != _academicSessionController?.contextGeneration) {
        return;
      }
      await store?.writeProfile(profile: profile);
    } catch (error) {
      debugPrint('保存教务 Profile 失败: ${error.runtimeType}');
    }
  }

  void _setPersistenceReadiness(String userId, String sourceAccountId) {
    final contextKey =
        '$userId|$sourceAccountId|${_academicSessionController?.identity?.storageId ?? ''}';
    if (contextKey == _persistenceContextKey) return;
    _persistenceContextKey = contextKey;
    final readiness = _loadPersistencePolicy(userId, sourceAccountId);
    _persistenceReady = readiness;
    AcademicPersistenceRegistry.setReadiness(userId, readiness);
  }

  Future<void> _loadPersistencePolicy(
    String userId,
    String sourceAccountId,
  ) async {
    final contextKey = _persistenceContextKey;
    final identity = _academicSessionController?.identity;
    AcademicPersistenceRegistry.set(userId, enabled: false);
    final storage = await AppPreferencesStore.getInstance();
    final prefs = AcademicStoragePreferences(
      appUserId: userId,
      identity: identity,
      store: storage,
    );
    await prefs.migrateLegacyPreferences();
    var enabled = prefs.saveAcademicData;
    if (!prefs.hasMigrated && sourceAccountId.isNotEmpty) {
      // 是否存在旧快照不能覆盖用户选择，也不能关闭新账号的课表保存能力。
      await prefs.markMigrated();
    }
    if (prefs.cleanupPending) enabled = false;
    if (_userId != userId ||
        contextKey != _persistenceContextKey ||
        identity != _academicSessionController?.identity) {
      return;
    }
    if (identity != null &&
        AcademicConnectionStore(identity, storage).cleanupPending) {
      enabled = false;
    }
    AcademicPersistenceRegistry.set(userId, enabled: enabled);
  }

  /// 将教务会话状态投影到旧 Provider 的兼容字段。
  ///
  /// 旧页面仍可读取 [isBound]、[studentId] 等字段；实际请求统一由
  /// [AcademicSessionController] 和仓储按当前来源发起，避免 Provider 再复制
  /// 一份本机/服务端分流规则。
  void _applyAcademicSessionState() {
    final controller = _academicSessionController;
    if (controller == null) return;

    final localState = controller.sessionState;
    final isLocalSource = controller.sourceKind == AcademicSourceKind.local;
    if (!isLocalSource) {
      _usingLocalAcademicSession = false;
      _isAuthorized = controller.isAuthenticated ||
          controller.studentId != null && controller.studentId!.isNotEmpty;
      _isBound = _isAuthorized;
      _sessionState = switch (localState) {
        SessionState.authenticated => 'active',
        SessionState.expired => 'expired',
        SessionState.awaitingCaptcha => 'awaiting_captcha',
        SessionState.authenticating => 'authenticating',
        SessionState.unauthenticated => _isBound ? 'expired' : 'unbound',
      };
      _studentId = controller.studentId ?? '';
      final profile = controller.profile;
      _name = profile?.name ?? '';
      _grade = profile?.grade ?? '';
      _college = profile?.college ?? '';
      _major = profile?.major ?? '';
      _errorMessage = controller.failure?.message;
      // 未成功读取服务端状态时，只能显示恢复中/恢复失败，不能把网络异常
      // 解释为“没有绑定”并引导用户重复输入账号密码。
      _statusLoaded = controller.hasResolvedServerBindingStatus;
      notifyListeners();
      return;
    }

    _usingLocalAcademicSession = true;
    // 服务端已确认的身份和本机学校会话是两个独立状态。启动时即使
    // 本机 Cookie/Artifact 尚未恢复，也必须保留“已绑定”投影，页面才能
    // 引导用户恢复本机会话，而不是要求重复绑定。
    final identity = controller.identity;
    final hasBoundIdentity = controller.hasBoundIdentity;
    _isAuthorized = hasBoundIdentity;
    _isBound = hasBoundIdentity;
    _sessionState = switch (localState) {
      SessionState.authenticated => 'active',
      SessionState.expired => 'expired',
      SessionState.awaitingCaptcha => 'awaiting_captcha',
      SessionState.authenticating => 'authenticating',
      SessionState.unauthenticated => hasBoundIdentity ? 'expired' : 'unbound',
    };
    _studentId = controller.studentId ?? identity?.studentId ?? '';
    final profile = controller.profile;
    _name = profile?.name ?? '';
    _grade = profile?.grade ?? '';
    _college = profile?.college ?? '';
    _major = profile?.major ?? '';
    _errorMessage = controller.failure?.message;
    _statusLoaded = true;
    notifyListeners();
  }

  static Map<String, dynamic> _rawCourseToLegacyMap(RawCourse course) {
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
        throw const ParseException(
          message: '本机课表记录缺少研究生节次元数据',
          code: 'COURSE_SECTION_INVALID',
        );
      }
      // 这里只把 Provider 行序转换为网格坐标，不能把“上午3”等标签
      // 当作本科第 3 节解析；原标签通过 period_label 继续向展示层传递。
      startSection = periodOrder + 1;
      endSection = startSection;
    } else {
      final section = _parseCourseSection(course.section);
      if (section == null) {
        throw const ParseException(
          message: '本机课表记录的节次字段无法映射',
          code: 'COURSE_SECTION_INVALID',
        );
      }
      startSection = section[0];
      endSection = section[1];
    }
    final weekday = int.tryParse(course.weekDay.trim());
    if (weekday == null || weekday < 1 || weekday > 7) {
      throw const ParseException(
        message: '本机课表记录的星期字段无效',
        code: 'COURSE_WEEKDAY_INVALID',
      );
    }
    final canonical = course.toCanonicalJson();
    final mapped = <String, dynamic>{
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
    }
    return mapped;
  }

  static List<int>? _parseCourseSection(String value) {
    final sectionMatch = RegExp(
      r'^\s*(\d+)\s*(?:[-~至到—–]\s*(\d+)\s*)?节?\s*$',
    ).firstMatch(value);
    final explicitGraduateMatch = RegExp(
      r'第\s*(\d+)\s*(?:[-~至到—–]\s*(\d+)\s*)?节\s*$',
    ).firstMatch(value.trim());
    final match = sectionMatch ?? explicitGraduateMatch;
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2) ?? match.group(1)!);
    if (start == null || end == null || start < 1 || end < start) return null;
    return <int>[start, end];
  }

  void setUserId(String userId) {
    if (_userId == userId) return;
    // 递增 generation，使旧 loadStatus 的后续无效
    _statusGeneration++;
    final generation = _statusGeneration;
    final expectedUserId = userId;

    // 立即清除旧用户的所有可见状态，避免短暂显示上一位用户信息
    if (_userId != null) {
      clearGradeCacheForUser(_userId!);
    }
    _userId = userId;
    AcademicPersistenceRegistry.set(userId, enabled: false);
    _isBound = false;
    _isAuthorized = false;
    _sessionState = 'unbound';
    _studentId = '';
    _name = '';
    _grade = '';
    _college = '';
    _major = '';
    _errorMessage = null;
    _statusLoaded = false;
    _setPersistenceReadiness(userId, _studentId.trim());
    notifyListeners();
    _applyAcademicSessionState();
    if (_usingLocalAcademicSession || _academicSessionController != null) {
      return;
    }
    // 没有本机控制器时也不访问服务端教务接口，保持未就绪状态。
    _statusLoaded = true;
    if (_userId == expectedUserId && generation == _statusGeneration) {
      notifyListeners();
    }
  }

  void syncSessionUser(String? userId) {
    if (userId == null || userId.isEmpty) {
      clearMemoryForAccountTransition();
      return;
    }
    setUserId(userId);
  }

  /// 同步清空可见个人数据，持久化清理由显式登出流程负责。
  void clearMemoryForAccountTransition() {
    if (_userId == null &&
        _studentId.isEmpty &&
        _gradeCache.isEmpty &&
        _gradeDetailCache.isEmpty &&
        _academicSituationCache.isEmpty &&
        _creditRequirementCache.isEmpty) {
      return;
    }
    _statusGeneration++;
    if (_userId != null) AcademicPersistenceRegistry.clear(_userId!);
    _persistenceContextKey = '';
    _userId = null;
    _isBound = false;
    _isAuthorized = false;
    _sessionState = 'unbound';
    _studentId = '';
    _name = '';
    _grade = '';
    _college = '';
    _major = '';
    _isLoading = false;
    _statusLoaded = false;
    _errorMessage = null;
    _gradeCache.clear();
    _gradeDetailCache.clear();
    _academicSituationCache.clear();
    _creditRequirementCache.clear();
    notifyListeners();
  }

  String? get userId => _userId;

  Future<void> ensureStatusLoaded() async {
    final controller = _academicSessionController;
    await controller?.prepareAccountContext();
    if (controller != null &&
        controller.sourceKind == AcademicSourceKind.legacy &&
        !controller.isAuthenticated) {
      try {
        await controller.restoreSession();
      } catch (_) {
        // 恢复错误由控制器保留，不能清除服务端绑定或伪装为恢复成功。
      }
      _applyAcademicSessionState();
      // 服务端状态不可达时保留未解析状态，调用方可呈现恢复失败而非未绑定。
      return;
    }
    // 状态由控制器通知驱动，失败保持未解析；不得无期限轮询等待。
    _applyAcademicSessionState();
  }

  /// 重新读取当前账号的教务状态，供 Agent 恢复原请求前确认会话确实可用。
  Future<void> refreshStatus() async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) return;
    await loadStatus(expectedUserId: userId, generation: _statusGeneration);
  }

  // 获取绑定状态
  Future<void> loadStatus({
    required String expectedUserId,
    required int generation,
  }) async {
    if (_userId != expectedUserId || generation != _statusGeneration) return;
    final controller = _academicSessionController;
    if (controller != null &&
        controller.sourceKind == AcademicSourceKind.legacy) {
      try {
        await controller.restoreSession(force: true);
      } catch (_) {}
      if (_userId != expectedUserId || generation != _statusGeneration) return;
    }
    _applyAcademicSessionState();
    if (!_statusLoaded && controller == null) {
      _statusLoaded = true;
      notifyListeners();
    }
  }

  Future<void> _clearBoundStatusFor(String userId) async {
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.remove('edu_bound_$userId');
    await prefs.remove('edu_authorized_$userId');
    await prefs.remove('edu_session_state_$userId');
    await prefs.remove('edu_student_id_$userId');
    await prefs.remove('edu_grade_$userId');
    await prefs.remove('edu_college_$userId');
    await prefs.remove('edu_major_$userId');
    await prefs.remove('edu_last_semester_$userId');
  }

  /// 清除本机教务登录态，不修改服务器绑定关系。
  Future<void> clearLocalSession() async {
    final controller = _academicSessionController;
    final identity = controller?.identity;
    if (controller != null && identity != null) {
      await AcademicIdentityLifecycleCoordinator(
              controller: controller,
              preferences: await AppPreferencesStore.getInstance())
          .clearLocalIdentity(identity);
      if (controller.identity != identity ||
          controller.appUserId != identity.appUserId) {
        return;
      }
      clearMemoryForAccountTransition();
      // 本机清除不撤销服务端身份，恢复绑定投影，避免页面误报未绑定。
      _userId = controller.appUserId;
      _applyAcademicSessionState();
      return;
    }
    // 先捕获命名空间：重置本机会话后 studentId 会被清空，不能再依赖当前
    // 字段定位成绩快照。退出本机教务必须同时撤销内存和加密缓存中的个人数据。
    final oldUserId = _userId;
    final oldSourceAccountId = _studentId.trim();
    final academicStore = oldUserId == null
        ? null
        : _academicCacheStoreFor(
            appUserId: oldUserId,
            sourceAccountId: oldSourceAccountId,
          );

    Object? cleanupError;
    Future<void> runCleanupStep(
      String label,
      Future<void> Function() step,
    ) async {
      try {
        await step();
      } catch (error) {
        cleanupError ??= error;
        debugPrint('$label失败: ${error.runtimeType}');
      }
    }

    await runCleanupStep(
      '重置本机教务会话',
      () async {
        final controller = _academicSessionController;
        if (controller != null) await controller.resetSession();
      },
    );
    await runCleanupStep(
      '清理教务内存状态',
      () async => clearMemoryForAccountTransition(),
    );
    if (academicStore != null) {
      await runCleanupStep('清理加密教务缓存', academicStore.clearAll);
    }
    if (oldUserId != null && oldUserId.isNotEmpty) {
      await runCleanupStep(
        '撤销本地教务绑定标记',
        () => _clearBoundStatusFor(oldUserId),
      );
    }
    if (cleanupError != null) {
      // 身份撤销已独立完成；只提示缓存清理异常，避免失败异常阻断退出流程。
      _errorMessage = '本地教务缓存清理未完成，请稍后重试';
      notifyListeners();
    }
  }

  // 绑定教务账号
  Future<bool> bind(
    String studentId,
    String password, {
    required bool eduDataConsentAccepted,
  }) async {
    if (!eduDataConsentAccepted) {
      _errorMessage = '请先阅读并同意教务数据专项授权';
      notifyListeners();
      return false;
    }
    final controller = _academicSessionController;
    if (controller == null ||
        controller.sourceKind != AcademicSourceKind.legacy) {
      _errorMessage = '教务服务未就绪，请稍后重试';
      notifyListeners();
      return false;
    }
    final result =
        await controller.login(studentId: studentId, password: password);
    if (result is LoginSuccess) {
      _applyAcademicSessionState();
      return true;
    }
    _errorMessage = controller.failure?.message ?? '教务绑定失败';
    notifyListeners();
    return false;
  }

  /// 服务端绑定必须撤销远端授权，否则重登 App 后会再次恢复绑定。
  Future<OperationResult<void>> unbind() async {
    final controller = _academicSessionController;
    final identity = controller?.identity;
    if (controller != null &&
        identity != null &&
        controller.providerRouter != null) {
      final router = controller.providerRouter!;
      try {
        await router.accountStore!.remove(identity.providerId, fromCloud: true);
        await controller.acceptIdentityUnbound(identity);
      } catch (_) {
        return OperationResult.fail('本机移除未完成，请重试');
      }
      try {
        await AcademicIdentityLifecycleCoordinator(
                controller: controller,
                preferences: await AppPreferencesStore.getInstance())
            .clearLocalIdentity(identity);
        await router.accountStore!.acknowledgeCleanup(identity);
      } catch (_) {
        _errorMessage = '账号已移除，本机残留资料待清理';
      }
      unawaited(router.syncConfiguration());
      _applyAcademicSessionState();
      return OperationResult.ok(null);
    }
    if (_academicSessionController?.sourceKind == AcademicSourceKind.legacy) {
      return revokeAuthorization();
    }
    await clearLocalSession();
    return OperationResult.ok(null);
  }

  Future<OperationResult<void>> logoutSession() async {
    try {
      await _dio.post('/edu/session/logout');
      await _academicSessionController?.resetSession();
      _applyAcademicSessionState();
      return OperationResult.ok(null);
    } on DioException catch (error) {
      return OperationResult.fail(error.message ?? '退出教务会话失败');
    }
  }

  Future<OperationResult<void>> resumeSession() async {
    final controller = _academicSessionController;
    if (controller == null ||
        controller.sourceKind != AcademicSourceKind.legacy) {
      return OperationResult.fail('教务服务未就绪');
    }
    try {
      await controller.restoreSession();
      _applyAcademicSessionState();
      return controller.isAuthenticated
          ? OperationResult.ok(null)
          : OperationResult.fail('教务绑定不存在');
    } on DioException catch (error) {
      return OperationResult.fail(error.message ?? '恢复教务会话失败');
    }
  }

  Future<OperationResult<void>> revokeAuthorization() async {
    try {
      await _dio.delete('/edu/authorization');
      await clearLocalSession();
      return OperationResult.ok(null);
    } on DioException catch (error) {
      return OperationResult.fail(error.message ?? '解除教务绑定失败');
    }
  }

  // 获取课表
  Future<OperationResult<List<Map<String, dynamic>>>?> getCourses(
    String year,
    int semester, {
    String? providerTermId,
  }) async {
    final requestUserId = _userId;
    final requestSourceAccountId = _studentId.trim();
    final requestSourceKind = _activeAcademicSourceKind;
    if (requestUserId == null) {
      return OperationResult.fail('用户未登录');
    }

    bool isCurrentContext() => _isSameAcademicContext(
          requestUserId,
          requestSourceAccountId,
          requestSourceKind,
        );

    final controller = _academicSessionController;
    if (controller == null) {
      return OperationResult.fail(
        '教务会话未就绪，请先恢复教务绑定',
        errorCode: 'ACADEMIC_SESSION_NOT_READY',
      );
    }
    if (requestSourceAccountId.isEmpty) {
      return OperationResult.fail('教务账号未就绪');
    }
    return _runEduRequest(() async {
      try {
        final result = await controller.loadCourses(
          year: year,
          semester: semester,
          providerTermId: providerTermId,
        );
        if (result == null) {
          final failure = controller.failure;
          _logAcademicCourseDiagnostic(
            stage: 'controller',
            failure: failure,
          );
          return OperationResult.fail(
            failure?.message ?? '获取课表失败',
            errorCode: failure?.code,
          );
        }
        if (!isCurrentContext()) {
          _logAcademicCourseDiagnostic(stage: 'context_changed');
          return OperationResult.fail('用户已切换');
        }
        try {
          return OperationResult.ok(
            result.courses.map(_rawCourseToLegacyMap).toList(growable: false),
          );
        } catch (error) {
          _logAcademicCourseDiagnostic(stage: 'legacy_mapping', error: error);
          rethrow;
        }
      } catch (error) {
        _logAcademicCourseDiagnostic(stage: 'edu_request', error: error);
        rethrow;
      }
    });
  }

  void _logAcademicCourseDiagnostic({
    required String stage,
    Object? error,
    AcademicFailure? failure,
  }) {
    if (!kDebugMode) return;
    final mappedFailure = failure ??
        (error == null ? null : AcademicFailure.fromException(error));
    final controller = _academicSessionController;
    final providerId = controller?.providerRouter?.selectedProviderId?.value ??
        controller?.providerId?.value ??
        (controller?.sourceKind == AcademicSourceKind.legacy
            ? 'legacy'
            : 'unknown');
    debugPrint(
      '教务课表诊断 stage=$stage runtimeType=${error?.runtimeType ?? 'none'} '
      'kind=${mappedFailure?.kind.name ?? 'none'} '
      'code=${mappedFailure?.code ?? 'none'} '
      'providerId=$providerId',
    );
  }

  /// 获取本机 Provider 从学校返回的真实学期列表。
  Future<OperationResult<List<AcademicTerm>>?> getAcademicTerms() async {
    final requestUserId = _userId;
    final requestSourceAccountId = _studentId.trim();
    final requestSourceKind = _activeAcademicSourceKind;
    if (requestUserId == null) return OperationResult.fail('用户未登录');
    if (requestSourceKind != AcademicSourceKind.local) return null;

    final controller = _academicSessionController;
    if (controller == null) {
      return OperationResult.fail(
        '教务会话未就绪，请先恢复教务绑定',
        errorCode: 'ACADEMIC_SESSION_NOT_READY',
      );
    }
    return _runEduRequest(() async {
      final terms = await controller.loadTerms();
      if (terms == null) {
        final failure = controller.failure;
        return OperationResult.fail(
          failure?.message ?? '获取学校学期列表失败',
          errorCode: failure?.code,
        );
      }
      if (!_isSameAcademicContext(
        requestUserId,
        requestSourceAccountId,
        requestSourceKind,
      )) {
        return OperationResult.fail('用户已切换');
      }
      return OperationResult.ok(terms);
    });
  }

  /// 从身份隔离的加密快照恢复成绩，不访问学校网络。
  Future<GradeCacheEntry?> restoreCachedGrades(
      String year, int semester) async {
    final memory = getCachedGrades(year, semester);
    if (memory != null) return memory;
    final user = _userId;
    final account = _studentId.trim();
    final source = _activeAcademicSourceKind;
    final generation = _academicSessionController?.contextGeneration;
    if (user == null || account.isEmpty) return null;
    await _persistenceReady;
    try {
      final snapshot = await _academicCacheStoreFor(
        appUserId: user,
        sourceAccountId: account,
      )?.readSnapshot();
      if (!_isSameAcademicContext(user, account, source) ||
          generation != _academicSessionController?.contextGeneration) {
        return null;
      }
      for (final term in snapshot?.terms.values ?? <AcademicTermSnapshot>[]) {
        _gradeCache.putIfAbsent(
            _cacheKeyFor(user, account, source, term.year, term.semester),
            () => GradeCacheEntry(
                grades: term.grades.map(EduGrade.fromJson).toList(),
                updatedAt: term.fetchedAt));
      }
      return getCachedGrades(year, semester);
    } catch (error) {
      debugPrint('读取加密成绩失败: ${error.runtimeType}');
      return null;
    }
  }

  /// 获取成绩 — 通过当前教务会话按需读取。
  /// 成功时自动写入内存缓存并记录更新时间。
  Future<OperationResult<List<EduGrade>>> fetchGrades(
    String year,
    int semester,
  ) async {
    // 捕获请求发起时的用户 ID，防止 await 后 _userId 被切换
    final requestUserId = _userId;
    if (requestUserId == null) {
      return OperationResult.fail('用户未登录');
    }
    await _persistenceReady;
    final requestSourceAccountId = _studentId.trim();
    final requestSourceKind = _activeAcademicSourceKind;
    final raw = await _fetchGradesRaw(year, semester);

    // 请求期间用户已切换 → 丢弃结果
    if (!_isSameAcademicContext(
      requestUserId,
      requestSourceAccountId,
      requestSourceKind,
    )) {
      return OperationResult.fail('用户已切换');
    }

    if (raw != null && raw.success && raw.data != null) {
      final grades = raw.data!.map((m) => EduGrade.fromJson(m)).toList();
      // 使用捕获的 requestUserId 生成缓存键，防止写入错误用户的缓存
      if (requestSourceAccountId.isNotEmpty) {
        _gradeCache[_cacheKeyFor(
          requestUserId,
          requestSourceAccountId,
          requestSourceKind,
          year,
          semester,
        )] = GradeCacheEntry(
          grades: grades,
          updatedAt: DateTime.now(),
        );
      }
      final store = _academicCacheStoreFor(
        appUserId: requestUserId,
        sourceAccountId: requestSourceAccountId,
      );
      String? storageWarning;
      if (store != null) {
        try {
          await store.writeGrades(
            year: year,
            semester: semester,
            grades: raw.data!,
          );
        } catch (error) {
          // 页面仍可使用本次响应；AI Gateway 没有成功密文时会返回缺失。
          debugPrint('保存加密成绩失败: ${error.runtimeType}');
          storageWarning = '成绩已获取，但保存加密成绩失败';
        }
      }
      if (!_isSameAcademicContext(
        requestUserId,
        requestSourceAccountId,
        requestSourceKind,
      )) {
        return OperationResult.fail('用户已切换');
      }
      return OperationResult(
          success: true,
          data: grades,
          errorMessage: storageWarning,
          errorCode: storageWarning == null ? null : 'local_storage_failed');
    }
    return OperationResult.fail(
      raw?.errorMessage ?? '获取成绩失败',
      errorCode: raw?.errorCode,
    );
  }

  /// 为个人助手同步从入学至今的全部有效学期，并在加密仓库中记录完整性。
  Future<OperationResult<int>> syncAllGrades() async {
    final requestUserId = _userId;
    final requestSourceAccountId = _studentId.trim();
    final requestSourceKind = _activeAcademicSourceKind;
    if (requestUserId == null || requestSourceAccountId.isEmpty) {
      return OperationResult.fail('请先完成教务绑定');
    }
    await _persistenceReady;
    final terms = EduSemester.buildSemesterList(enrollmentYear);
    var syncedTerms = 0;
    String? lastError;
    String? lastErrorCode;
    for (final term in terms) {
      final result = await fetchGrades(term.year, term.semester);
      if (!_isSameAcademicContext(
        requestUserId,
        requestSourceAccountId,
        requestSourceKind,
      )) {
        return OperationResult.fail('用户已切换');
      }
      if (result.success) {
        syncedTerms++;
      } else {
        lastError = result.errorMessage;
        lastErrorCode = result.errorCode;
        break;
      }
    }
    if (syncedTerms == terms.length) {
      final store = _academicCacheStoreFor(
        appUserId: requestUserId,
        sourceAccountId: requestSourceAccountId,
      );
      try {
        await store?.markGradeSyncComplete();
      } catch (error) {
        debugPrint('保存成绩完整同步标记失败: ${error.runtimeType}');
        return OperationResult.fail(
          '成绩已获取，但保存加密成绩失败',
          errorCode: 'local_storage_failed',
        );
      }
      return OperationResult.ok(syncedTerms);
    }
    if (syncedTerms > 0) {
      // 部分学期可用时仍返回已同步数量，Gateway 会标记为需要刷新并明确提示范围不完整。
      return OperationResult(
        success: true,
        data: syncedTerms,
        errorMessage: '仅同步了部分学期，已保留已有缓存',
        errorCode: 'refresh_incomplete',
      );
    }
    return OperationResult.fail(
      lastError ?? '自动同步成绩失败',
      errorCode: lastErrorCode,
    );
  }

  Future<OperationResult<EduGradeDetail>> fetchGradeDetail(
    EduGrade grade,
    String year,
    int semester, {
    bool forceRefresh = false,
  }) =>
      _fetchGradeDetail(grade, year, semester, forceRefresh: forceRefresh);

  Future<OperationResult<EduGradeDetail>> _fetchGradeDetail(
    EduGrade grade,
    String year,
    int semester, {
    bool forceRefresh = false,
    bool background = false,
  }) async {
    final requestUserId = _userId;
    final sourceAccountId = _studentId.trim();
    final sourceKind = _activeAcademicSourceKind;
    if (requestUserId == null || sourceAccountId.isEmpty) {
      return OperationResult.fail('请先恢复教务绑定',
          errorCode: 'credentials_required');
    }
    await _persistenceReady;
    final key = _gradeDetailCacheKey(grade, year, semester);
    if (!forceRefresh) {
      final cached = _gradeDetailCache[key];
      if (cached != null) return OperationResult.ok(cached);
      final store = _academicCacheStoreFor(
        appUserId: requestUserId,
        sourceAccountId: sourceAccountId,
      );
      final raw = await store?.readGradeDetail(key);
      if (raw != null &&
          _isSameAcademicContext(requestUserId, sourceAccountId, sourceKind)) {
        final cachedDetail = EduGradeDetail.fromJson(raw);
        _gradeDetailCache[key] = cachedDetail;
        return OperationResult.ok(cachedDetail);
      }
    }
    final controller = _academicSessionController;
    if (controller == null) {
      return OperationResult.fail(
        '教务会话未就绪，请先恢复教务绑定',
        errorCode: 'ACADEMIC_SESSION_NOT_READY',
      );
    }
    return _runEduRequest(() async {
      final detail = await controller.loadGradeDetail(
        year: year,
        semester: semester,
        classId: grade.classId,
        courseName: grade.name,
        courseId: grade.courseId,
        studentGradeId: grade.studentGradeId,
      );
      if (detail == null ||
          !_isSameAcademicContext(requestUserId, sourceAccountId, sourceKind)) {
        return OperationResult.fail(
          controller.failure?.message ?? '获取成绩构成失败',
          errorCode: controller.failure?.code,
        );
      }
      final value = EduGradeDetail.fromJson(detail.toJson());
      _gradeDetailCache[key] = value;
      try {
        await _academicCacheStoreFor(
          appUserId: requestUserId,
          sourceAccountId: sourceAccountId,
        )?.writeGradeDetail(key: key, detail: detail.toJson());
      } catch (error) {
        debugPrint('保存成绩详情失败: ${error.runtimeType}');
        return OperationResult(
          success: true,
          data: value,
          errorMessage: '成绩构成已获取，但保存本地资料失败',
          errorCode: 'local_storage_failed',
        );
      }
      return OperationResult.ok(value);
    }, background: background);
  }

  /// 在成绩列表稳定后按展示顺序预取构成明细，避免进入详情页时逐门等待。
  ///
  /// 预取串行执行并在课程间留出间隔，让用户主动发起的教务请求优先获得执行机会。
  Future<void> prefetchGradeDetails(
    List<EduGrade> grades,
    String year,
    int semester, {
    Duration initialDelay = const Duration(milliseconds: 300),
  }) {
    return _prefetchGradeDetails(grades, year, semester, initialDelay);
  }

  Future<void> _prefetchGradeDetails(
    List<EduGrade> grades,
    String year,
    int semester,
    Duration initialDelay,
  ) async {
    if (_userId == null || _studentId.trim().isEmpty) return;
    final controller = _academicSessionController;
    if (controller == null) return;
    final user = _userId!;
    final account = _studentId.trim();
    final source = _activeAcademicSourceKind;
    final generation = controller.contextGeneration;
    if (initialDelay > Duration.zero) await Future<void>.delayed(initialDelay);
    for (final grade in grades) {
      if (!_isSameAcademicContext(user, account, source) ||
          controller.contextGeneration != generation) {
        return;
      }
      await _fetchGradeDetail(grade, year, semester, background: true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<AcademicSituationCacheEntry?> restoreCachedAcademicSituation() async {
    final memory = getCachedAcademicSituation();
    if (memory != null) return memory;
    final user = _userId;
    final account = _studentId.trim();
    final source = _activeAcademicSourceKind;
    final generation = _academicSessionController?.contextGeneration;
    if (user == null || account.isEmpty) return null;
    await _persistenceReady;
    try {
      final raw = await _academicCacheStoreFor(
        appUserId: user,
        sourceAccountId: account,
      )?.readAcademicSituation();
      if (raw == null ||
          generation != _academicSessionController?.contextGeneration ||
          !_isSameAcademicContext(user, account, source)) {
        return null;
      }
      final entry = AcademicSituationCacheEntry(
          data: EduAcademicSituation.fromJson(raw), updatedAt: DateTime.now());
      _academicSituationCache[
          _academicSituationCacheKey(user, account, source)] = entry;
      return entry;
    } catch (error) {
      // 本地快照异常不阻断后续网络刷新，也不输出个人教务内容。
      debugPrint("恢复教务概览缓存失败: ${error.runtimeType}");
      return null;
    }
  }

  Future<CreditRequirementCacheEntry?> restoreCachedCreditRequirements() async {
    final memory = getCachedCreditRequirements();
    if (memory != null) return memory;
    final user = _userId;
    final account = _studentId.trim();
    final source = _activeAcademicSourceKind;
    final generation = _academicSessionController?.contextGeneration;
    if (user == null || account.isEmpty) return null;
    await _persistenceReady;
    try {
      final raw = await _academicCacheStoreFor(
        appUserId: user,
        sourceAccountId: account,
      )?.readCreditRequirements();
      if (raw == null ||
          generation != _academicSessionController?.contextGeneration ||
          !_isSameAcademicContext(user, account, source)) {
        return null;
      }
      final entry = CreditRequirementCacheEntry(
          data: EduCreditRequirementOverview.fromJson(raw),
          updatedAt: DateTime.now());
      _creditRequirementCache[
          _creditRequirementCacheKey(user, account, source)] = entry;
      return entry;
    } catch (error) {
      // 本地快照异常不阻断后续网络刷新，也不输出个人教务内容。
      debugPrint("恢复教务概览缓存失败: ${error.runtimeType}");
      return null;
    }
  }

  Future<OperationResult<EduAcademicSituation>> fetchAcademicSituation(
      {bool forceRefresh = false}) async {
    final requestUserId = _userId;
    final sourceAccountId = _studentId.trim();
    final sourceKind = _activeAcademicSourceKind;
    if (requestUserId == null || sourceAccountId.isEmpty) {
      return OperationResult.fail('请先恢复教务绑定',
          errorCode: 'credentials_required');
    }
    await _persistenceReady;
    final key = _academicSituationCacheKey(
      requestUserId,
      sourceAccountId,
      sourceKind,
    );
    final cached = _academicSituationCache[key];
    if (!forceRefresh && cached != null) return OperationResult.ok(cached.data);
    final cachedRaw = forceRefresh
        ? null
        : await _academicCacheStoreFor(
            appUserId: requestUserId,
            sourceAccountId: sourceAccountId,
          )?.readAcademicSituation();
    if (cachedRaw != null &&
        _isSameAcademicContext(requestUserId, sourceAccountId, sourceKind)) {
      final value = EduAcademicSituation.fromJson(cachedRaw);
      _academicSituationCache[key] = AcademicSituationCacheEntry(
        data: value,
        updatedAt: DateTime.now(),
      );
      return OperationResult.ok(value);
    }
    final controller = _academicSessionController;
    if (controller == null) {
      return OperationResult.fail(
        '教务会话未就绪，请先恢复教务绑定',
        errorCode: 'ACADEMIC_SESSION_NOT_READY',
      );
    }
    return _runEduRequest(() async {
      final result = await controller.loadAcademicSituation();
      if (result == null ||
          !_isSameAcademicContext(requestUserId, sourceAccountId, sourceKind)) {
        return OperationResult.fail(
          controller.failure?.message ?? '获取学业情况失败',
          errorCode: controller.failure?.code,
        );
      }
      final value = EduAcademicSituation.fromJson(result.toJson());
      _academicSituationCache[key] = AcademicSituationCacheEntry(
        data: value,
        updatedAt: DateTime.now(),
      );
      try {
        await _academicCacheStoreFor(
          appUserId: requestUserId,
          sourceAccountId: sourceAccountId,
        )?.writeAcademicSituation(data: result.toJson());
      } catch (error) {
        debugPrint('保存学业情况失败: ${error.runtimeType}');
      }
      return OperationResult.ok(value);
    });
  }

  // 获取成绩（原始数据，内部使用）
  Future<OperationResult<List<Map<String, dynamic>>>?> _fetchGradesRaw(
    String year,
    int semester,
  ) async {
    if (_userId == null) {
      return OperationResult.fail('用户未登录');
    }

    final controller = _academicSessionController;
    if (controller != null) {
      return _runEduRequest(() async {
        final result =
            await controller.loadGrades(year: year, semester: semester);
        if (result == null) {
          final failure = controller.failure;
          return OperationResult.fail(
            failure?.message ?? '获取成绩失败',
            errorCode: failure?.code,
          );
        }
        return OperationResult.ok(
          result.grades.map(RawGradeMapper.toAppJson).toList(growable: false),
        );
      });
    }

    return OperationResult.fail(
      '教务会话未就绪，请先恢复教务绑定',
      errorCode: 'ACADEMIC_SESSION_NOT_READY',
    );
  }

  Future<OperationResult<EduCreditRequirementOverview>> fetchCreditRequirements(
      {bool forceRefresh = false}) async {
    final requestUserId = _userId;
    final sourceAccountId = _studentId.trim();
    final sourceKind = _activeAcademicSourceKind;
    if (requestUserId == null || sourceAccountId.isEmpty) {
      return OperationResult.fail('请先恢复教务绑定',
          errorCode: 'credentials_required');
    }
    await _persistenceReady;
    final key = _creditRequirementCacheKey(
      requestUserId,
      sourceAccountId,
      sourceKind,
    );
    final cached = _creditRequirementCache[key];
    if (!forceRefresh && cached != null) return OperationResult.ok(cached.data);
    final cachedRaw = forceRefresh
        ? null
        : await _academicCacheStoreFor(
            appUserId: requestUserId,
            sourceAccountId: sourceAccountId,
          )?.readCreditRequirements();
    if (cachedRaw != null &&
        _isSameAcademicContext(requestUserId, sourceAccountId, sourceKind)) {
      final value = EduCreditRequirementOverview.fromJson(cachedRaw);
      _creditRequirementCache[key] = CreditRequirementCacheEntry(
        data: value,
        updatedAt: DateTime.now(),
      );
      return OperationResult.ok(value);
    }
    final controller = _academicSessionController;
    if (controller == null) {
      return OperationResult.fail(
        '教务会话未就绪，请先恢复教务绑定',
        errorCode: 'ACADEMIC_SESSION_NOT_READY',
      );
    }
    return _runEduRequest(() async {
      final result = await controller.loadCreditRequirements();
      if (result == null ||
          !_isSameAcademicContext(requestUserId, sourceAccountId, sourceKind)) {
        return OperationResult.fail(
          controller.failure?.message ?? '获取学分要求失败',
          errorCode: controller.failure?.code,
        );
      }
      final value = EduCreditRequirementOverview.fromJson(result.toJson());
      _creditRequirementCache[key] = CreditRequirementCacheEntry(
        data: value,
        updatedAt: DateTime.now(),
      );
      try {
        await _academicCacheStoreFor(
          appUserId: requestUserId,
          sourceAccountId: sourceAccountId,
        )?.writeCreditRequirements(data: result.toJson());
      } catch (error) {
        debugPrint('保存学分要求失败: ${error.runtimeType}');
      }
      return OperationResult.ok(value);
    });
  }

  @override
  void dispose() {
    _academicSessionController?.removeListener(_onAcademicSessionChanged);
    super.dispose();
  }
}
