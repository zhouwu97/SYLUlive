import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart' hide AcademicCapabilities;

import '../features/campus_data/storage/academic_cache_store.dart';
import '../features/campus_data/storage/account_scoped_snapshot_store.dart';
import '../features/campus_data/storage/personal_snapshot_models.dart';
import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/storage/academic_persistence_gate.dart';
import '../features/academic/storage/academic_storage_preferences.dart';
import '../features/academic/data/mapper/raw_grade_mapper.dart';
import '../features/academic/domain/academic_repository.dart';
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

  Future<T> _runEduRequest<T>(Future<T> Function() task) async {
    while (_eduRequestBusy) {
      await Future.delayed(const Duration(milliseconds: 120));
    }
    _eduRequestBusy = true;
    try {
      return await task();
    } finally {
      _eduRequestBusy = false;
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
  ]) : _snapshotStoreBuilder = snapshotStoreBuilder;

  /// 接入本机教务会话；服务端教务代理不再作为运行时数据源。
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
    try {
      await _persistenceReady;
      await _academicCacheStoreFor(
        appUserId: userId,
        sourceAccountId: sourceAccountId,
      )?.writeProfile(profile: profile);
    } catch (error) {
      debugPrint('保存教务 Profile 失败: ${error.runtimeType}');
    }
  }

  void _setPersistenceReadiness(String userId, String sourceAccountId) {
    final contextKey = '$userId|$sourceAccountId';
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
    AcademicPersistenceRegistry.set(userId, enabled: false);
    final prefs = AcademicStoragePreferences(
      appUserId: userId,
      store: await AppPreferencesStore.getInstance(),
    );
    var enabled = prefs.saveAcademicData;
    if (!prefs.hasMigrated && sourceAccountId.isNotEmpty) {
      // 升级前已有 Vault 时保留离线体验；新账号没有快照则保持默认关闭。
      try {
        final vault = AesGcmAccountScopedSnapshotStore(appUserId: userId);
        final academic = await vault.read(
          type: PersonalDataType.academic,
          sourceSystem: 'edu',
          sourceAccountId: sourceAccountId,
        );
        final schedule = await vault.read(
          type: PersonalDataType.schedule,
          sourceSystem: 'edu',
          sourceAccountId: sourceAccountId,
        );
        enabled = academic != null || schedule != null;
        await prefs.setSaveAcademicData(enabled);
        await prefs.markMigrated();
      } catch (_) {}
    }
    if (prefs.cleanupPending) enabled = false;
    AcademicPersistenceRegistry.set(userId, enabled: enabled);
  }

  /// 将本机直连状态投影到旧 Provider 的兼容字段。
  ///
  /// 旧页面仍可读取 [isBound]、[studentId] 等字段，但网络请求是否走本机
  /// 直连由下面的本地分支决定；本地状态不会写入旧的服务端绑定偏好设置。
  void _applyAcademicSessionState() {
    final controller = _academicSessionController;
    if (controller == null) return;

    final localState = controller.sessionState;
    final isLocalSource = controller.sourceKind == AcademicSourceKind.local;
    if (!isLocalSource) {
      if (!_usingLocalAcademicSession) return;
      _usingLocalAcademicSession = false;
      _isBound = false;
      _isAuthorized = false;
      _sessionState = 'unbound';
      _studentId = '';
      _name = '';
      _grade = '';
      _college = '';
      _major = '';
      _statusLoaded = false;
      notifyListeners();
      final userId = _userId;
      if (userId != null && userId.isNotEmpty) {
        unawaited(
          loadStatus(
            expectedUserId: userId,
            generation: _statusGeneration,
          ),
        );
      }
      return;
    }

    _usingLocalAcademicSession = true;
    _isAuthorized = controller.isAuthenticated;
    _isBound = _isAuthorized;
    _sessionState = switch (localState) {
      SessionState.authenticated => 'active',
      SessionState.expired => 'expired',
      SessionState.awaitingCaptcha => 'awaiting_captcha',
      SessionState.authenticating => 'authenticating',
      SessionState.unauthenticated => 'unbound',
    };
    _studentId = controller.studentId ?? '';
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
    final sectionMatch = RegExp(
      r'^\s*(\d+)\s*(?:[-~至到—–]\s*(\d+)\s*)?节?\s*$',
    ).firstMatch(course.section);
    final startSection =
        sectionMatch == null ? null : int.tryParse(sectionMatch.group(1)!);
    final endSection = sectionMatch == null
        ? null
        : int.tryParse(sectionMatch.group(2) ?? sectionMatch.group(1)!);
    if (startSection == null ||
        endSection == null ||
        startSection < 1 ||
        endSection < startSection) {
      throw const ProtocolChangedException(message: '本机课表记录缺少有效节次');
    }

    final weekday = int.tryParse(course.weekDay.trim());
    if (weekday == null || weekday < 1 || weekday > 7) {
      throw const ProtocolChangedException(message: '本机课表记录缺少有效星期');
    }
    final canonical = course.toCanonicalJson();
    return {
      'name': course.name,
      'teacher': course.teacher,
      'location': course.location,
      'weekday': weekday,
      'start_section': startSection,
      'end_section': endSection,
      'weekExpression': canonical['weekExpression'] ?? course.weekExpression,
      'weeks': canonical['weeks'] ?? const <int>[],
    };
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
    while (!_statusLoaded) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
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
    _applyAcademicSessionState();
    if (!_statusLoaded) {
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
    _errorMessage = '服务端教务绑定已关闭，请使用本机直连教务';
    notifyListeners();
    return false;
  }

  /// 兼容旧页面的“解绑”入口，现仅清除本机教务会话。
  Future<OperationResult<void>> unbind() async {
    await clearLocalSession();
    return OperationResult.ok(null);
  }

  Future<OperationResult<void>> logoutSession() async {
    await clearLocalSession();
    return OperationResult.ok(null);
  }

  Future<OperationResult<void>> resumeSession() async {
    return OperationResult.fail('本机教务会话不支持服务端恢复，请重新登录本机教务');
  }

  Future<OperationResult<void>> revokeAuthorization() async {
    await clearLocalSession();
    return OperationResult.ok(null);
  }

  // 获取课表
  Future<OperationResult<List<Map<String, dynamic>>>?> getCourses(
    String year,
    int semester,
  ) async {
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

    final localController = _academicSessionController;
    if (localController != null &&
        localController.sourceKind == AcademicSourceKind.local) {
      if (requestSourceAccountId.isEmpty) {
        return OperationResult.fail('教务账号未就绪');
      }
      return _runEduRequest(() async {
        final result = await localController.loadCourses(
          year: year,
          semester: semester,
        );
        if (result == null) {
          final failure = localController.failure;
          return OperationResult.fail(
            failure?.message ?? '获取课表失败',
            errorCode: failure?.code,
          );
        }
        if (!isCurrentContext()) return OperationResult.fail('用户已切换');
        return OperationResult.ok(
          result.courses.map(_rawCourseToLegacyMap).toList(growable: false),
        );
      });
    }

    return OperationResult.fail(
      '本机教务会话未就绪，请先登录本机教务',
      errorCode: 'LOCAL_SESSION_NOT_READY',
    );
  }

  /// 获取成绩 — 通过本机教务会话按需读取。
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
      final store = _academicCacheStoreFor(
        appUserId: requestUserId,
        sourceAccountId: requestSourceAccountId,
      );
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
          return OperationResult.fail(
            '成绩已获取，但保存加密成绩失败',
            errorCode: 'local_storage_failed',
          );
        }
      }
      if (!_isSameAcademicContext(
        requestUserId,
        requestSourceAccountId,
        requestSourceKind,
      )) {
        return OperationResult.fail('用户已切换');
      }
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
      return OperationResult.ok(grades);
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
  }) async {
    final requestUserId = _userId;
    final sourceAccountId = _studentId.trim();
    final sourceKind = _activeAcademicSourceKind;
    if (requestUserId == null || sourceAccountId.isEmpty) {
      return OperationResult.fail('请先登录本机教务',
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
    if (controller == null ||
        controller.sourceKind != AcademicSourceKind.local) {
      return OperationResult.fail('本机教务会话未就绪',
          errorCode: 'LOCAL_SESSION_NOT_READY');
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
    });
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
    if (controller == null ||
        controller.sourceKind != AcademicSourceKind.local) {
      return;
    }
    if (initialDelay > Duration.zero) await Future<void>.delayed(initialDelay);
    for (final grade in grades) {
      if (_userId == null) return;
      await fetchGradeDetail(grade, year, semester);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<OperationResult<EduAcademicSituation>> fetchAcademicSituation() async {
    final requestUserId = _userId;
    final sourceAccountId = _studentId.trim();
    final sourceKind = _activeAcademicSourceKind;
    if (requestUserId == null || sourceAccountId.isEmpty) {
      return OperationResult.fail('请先登录本机教务',
          errorCode: 'credentials_required');
    }
    await _persistenceReady;
    final key = _academicSituationCacheKey(
      requestUserId,
      sourceAccountId,
      sourceKind,
    );
    final cached = _academicSituationCache[key];
    if (cached != null) return OperationResult.ok(cached.data);
    final cachedRaw = await _academicCacheStoreFor(
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
    if (controller == null ||
        controller.sourceKind != AcademicSourceKind.local) {
      return OperationResult.fail('本机教务会话未就绪',
          errorCode: 'LOCAL_SESSION_NOT_READY');
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

    final localController = _academicSessionController;
    if (localController != null &&
        localController.sourceKind == AcademicSourceKind.local) {
      return _runEduRequest(() async {
        final result = await localController.loadGrades(
          year: year,
          semester: semester,
        );
        if (result == null) {
          final failure = localController.failure;
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
      '本机教务会话未就绪，请先登录本机教务',
      errorCode: 'LOCAL_SESSION_NOT_READY',
    );
  }

  Future<OperationResult<EduCreditRequirementOverview>>
      fetchCreditRequirements() async {
    final requestUserId = _userId;
    final sourceAccountId = _studentId.trim();
    final sourceKind = _activeAcademicSourceKind;
    if (requestUserId == null || sourceAccountId.isEmpty) {
      return OperationResult.fail('请先登录本机教务',
          errorCode: 'credentials_required');
    }
    await _persistenceReady;
    final key = _creditRequirementCacheKey(
      requestUserId,
      sourceAccountId,
      sourceKind,
    );
    final cached = _creditRequirementCache[key];
    if (cached != null) return OperationResult.ok(cached.data);
    final cachedRaw = await _academicCacheStoreFor(
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
    if (controller == null ||
        controller.sourceKind != AcademicSourceKind.local) {
      return OperationResult.fail('本机教务会话未就绪',
          errorCode: 'LOCAL_SESSION_NOT_READY');
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
