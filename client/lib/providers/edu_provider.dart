import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../features/campus_data/storage/academic_cache_store.dart';
import '../features/campus_data/storage/account_scoped_snapshot_store.dart';
import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/data/mapper/raw_grade_mapper.dart';
import '../features/academic/domain/academic_repository.dart';
import '../utils/app_feedback.dart';
import '../models/edu_academic_situation.dart';
import '../models/edu_credit_requirement.dart';
import '../models/edu_grade.dart';
import '../utils/edu_semester_utils.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

const _eduLongRequestTimeout = Duration(seconds: 25);

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
  late final Dio _authDio; // Go 服务器（获取当前用户信息）
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
  final Map<String, Future<OperationResult<EduGradeDetail>>>
      _gradeDetailRequests = {};
  final Map<String, Future<void>> _gradeDetailPrefetchJobs = {};
  final Map<String, AcademicSituationCacheEntry> _academicSituationCache = {};
  final Map<String, CreditRequirementCacheEntry> _creditRequirementCache = {};
  int _statusGeneration = 0;
  bool _eduRequestBusy = false;
  Future<void> Function(String token, Map<String, dynamic> user)?
      _applyAuthPayload;
  Future<void> Function()? _refreshAuthUser;
  AcademicSessionController? _academicSessionController;
  bool _usingLocalAcademicSession = false;

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
      const AcademicCapabilities.legacy();
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
    return _usingLocalAcademicSession
        ? AcademicSourceKind.local
        : AcademicSourceKind.legacy;
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
    if (_usingLocalAcademicSession ||
        userId == null ||
        sourceAccountId.isEmpty) {
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
    if (_usingLocalAcademicSession ||
        userId == null ||
        sourceAccountId.isEmpty) {
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
    _gradeDetailRequests.removeWhere((key, _) => key.startsWith('$userId|'));
    _gradeDetailPrefetchJobs
        .removeWhere((key, _) => key.startsWith('$userId|'));
    _academicSituationCache.removeWhere(
      (key, _) => key.startsWith('edu_academic_situation_${userId}_'),
    );
    _creditRequirementCache.removeWhere(
      (key, _) => key.startsWith('edu_credit_requirements_${userId}_'),
    );
  }

  /// 撤销教务授权后销毁该账号的本地个人数据保险箱。
  ///
  /// 课表、成绩、体测等快照均依赖教务专项授权，不能在撤销后继续保留。
  Future<void> _clearSensitiveEduSnapshots(String userId) async {
    final store = _snapshotStoreBuilder?.call(userId) ??
        AesGcmAccountScopedSnapshotStore(appUserId: userId);
    await store.clearUser();
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
    if (_usingLocalAcademicSession || _studentId.trim().isEmpty) return null;
    return _gradeDetailCache[_gradeDetailCacheKey(grade, year, semester)];
  }

  EduProvider(
    Dio authDio, [
    AccountScopedSnapshotStore Function(String appUserId)? snapshotStoreBuilder,
  ])  : _snapshotStoreBuilder = snapshotStoreBuilder,
        _authDio = authDio;

  /// 由认证提供者注入，使绑定学号返回的新令牌能与用户资料原子落盘。
  void setAuthCallbacks({
    Future<void> Function(String token, Map<String, dynamic> user)?
        applyAuthPayload,
    Future<void> Function()? refreshAuthUser,
  }) {
    _applyAuthPayload = applyAuthPayload;
    _refreshAuthUser = refreshAuthUser;
  }

  /// 接入 Batch 5 本机教务会话；旧服务端代理仅在显式选择 legacy 来源时使用。
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
    notifyListeners();
    _applyAcademicSessionState();
    if (_usingLocalAcademicSession) return;
    // 再异步加载新用户状态，携带 generation 防止覆盖
    loadStatus(
      expectedUserId: expectedUserId,
      generation: generation,
    );
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
    _gradeDetailRequests.clear();
    _gradeDetailPrefetchJobs.clear();
    _academicSituationCache.clear();
    _creditRequirementCache.clear();
    notifyListeners();
  }

  String? get userId => _userId;

  /// 解析Dio异常并返回友好的错误信息
  String _parseDioError(DioException e) {
    final statusCode = e.response?.statusCode;
    debugPrint(
      'Edu Dio error: path=${e.requestOptions.uri.path} '
      'status=$statusCode type=${e.type}',
    );
    return AppFeedback.dioErrorMessage(
      e,
      serviceName: '教务服务',
      fallback: '教务操作失败，请稍后再试',
    );
  }

  String? _eduFailureCode(DioException e) {
    final payload = e.response?.data;
    final values = <String>[];
    if (payload is Map) {
      for (final key in const ['code', 'error_code', 'upstream_code']) {
        final value = payload[key]?.toString().trim();
        if (value != null && value.isNotEmpty) values.add(value);
      }
    }
    for (final value in values) {
      switch (value.toUpperCase()) {
        case 'EDU_AUTHORIZATION_REVOKED':
          return 'edu_authorization_revoked';
        case 'EDU_SESSION_LOGGED_OUT':
          return 'edu_session_logged_out';
        case 'EDU_SESSION_EXPIRED':
          return 'edu_session_expired';
        case 'EDU_CREDENTIAL_UNAVAILABLE':
          return 'credential_unavailable';
      }
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError =>
        'network_unavailable',
      _ => null,
    };
  }

  String? _eduPayloadCode(Object? payload) {
    if (payload is! Map) return null;
    final value = payload['error_code'] ?? payload['code'];
    final code = value?.toString().trim();
    if (code == null || code.isEmpty) return null;
    switch (code.toUpperCase()) {
      case 'EDU_AUTHORIZATION_REVOKED':
        return 'edu_authorization_revoked';
      case 'EDU_SESSION_LOGGED_OUT':
        return 'edu_session_logged_out';
      case 'EDU_SESSION_EXPIRED':
        return 'edu_session_expired';
      case 'EDU_CREDENTIAL_UNAVAILABLE':
        return 'credential_unavailable';
      default:
        return code.toLowerCase();
    }
  }

  String _eduFailureMessage(String code) => switch (code) {
        'edu_authorization_revoked' ||
        'edu_session_logged_out' ||
        'edu_session_expired' ||
        'credential_unavailable' =>
          '教务会话已失效，请在账号与安全中手动恢复或重新授权',
        'network_unavailable' => '教务服务网络连接失败，请稍后重试',
        _ => '教务操作失败，请稍后重试',
      };

  OperationResult<T> _failFromDio<T>(DioException error, String fallback) {
    final code = _eduFailureCode(error);
    return OperationResult.fail(
      code == null
          ? (error.response == null ? fallback : _parseDioError(error))
          : _eduFailureMessage(code),
      errorCode: code,
    );
  }

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
    if (_usingLocalAcademicSession) return;
    // 极速上屏：先从本地缓存读取状态
    final cached = await _loadBoundStatusFor(expectedUserId);
    final cachedSessionState = _sessionState;

    // 检查是否已被新请求废弃
    if (_userId != expectedUserId || generation != _statusGeneration) {
      return;
    }

    if (!_statusLoaded) {
      _statusLoaded = true;
      notifyListeners();
    }

    try {
      final response = await _authDio.get('/edu/status');

      if (_userId != expectedUserId || generation != _statusGeneration) {
        return;
      }
      if (_usingLocalAcademicSession) return;

      if (response.statusCode == 200) {
        final data = response.data;
        _isAuthorized = data['edu_authorized'] == true;
        _isBound = _isAuthorized;
        _sessionState = data['edu_session_state']?.toString() ??
            (_isAuthorized ? 'active' : 'unbound');
        _studentId = data['edu_student_id'] ?? '';
        _name = data['name'] ?? '';
        _grade = data['edu_grade'] ?? '';
        _college = data['edu_college'] ?? '';
        _major = data['edu_major'] ?? '';
        _errorMessage = null;
        _statusLoaded = true;

        // _saveBoundStatusFor 使用捕获的 userId
        await _saveBoundStatusFor(expectedUserId);
        notifyListeners();
      }
    } on DioException catch (e) {
      if (_userId != expectedUserId || generation != _statusGeneration) {
        return;
      }
      _isBound = cached;
      _isAuthorized = cached;
      _sessionState = cachedSessionState;
      _errorMessage = _parseDioError(e);
      _statusLoaded = true;
      debugPrint('获取教务状态失败: $_errorMessage，使用缓存: $cached');
      notifyListeners();
    }
  }

  /// 保存绑定状态 — 使用显式 userId，不从可变字段读取
  Future<void> _saveBoundStatusFor(String userId) async {
    final prefs = await AppPreferencesStore.getInstance();
    await prefs.setBool('edu_authorized_$userId', _isAuthorized);
    await prefs.setString('edu_session_state_$userId', _sessionState);
    await prefs.setString('edu_student_id_$userId', _studentId);
    await prefs.setString('edu_grade_$userId', _grade);
    await prefs.setString('edu_college_$userId', _college);
    await prefs.setString('edu_major_$userId', _major);
  }

  /// 读取绑定状态 — 使用显式 userId
  Future<bool> _loadBoundStatusFor(String userId) async {
    final prefs = await AppPreferencesStore.getInstance();
    _studentId = prefs.getString('edu_student_id_$userId') ?? '';
    _grade = prefs.getString('edu_grade_$userId') ?? '';
    _college = prefs.getString('edu_college_$userId') ?? '';
    _major = prefs.getString('edu_major_$userId') ?? '';
    final hasLifecycleStatus = prefs.containsKey('edu_authorized_$userId') ||
        prefs.containsKey('edu_session_state_$userId');
    if (hasLifecycleStatus) {
      _isAuthorized = prefs.getBool('edu_authorized_$userId') ?? false;
      _sessionState = prefs.getString('edu_session_state_$userId') ??
          (_isAuthorized ? 'active' : 'unbound');
    } else {
      // 仅为旧版本缓存迁移一次，之后始终以授权和会话状态两个字段为准。
      _isAuthorized = prefs.getBool('edu_bound_$userId') ?? false;
      _sessionState = _isAuthorized ? 'active' : 'unbound';
      await prefs.setBool('edu_authorized_$userId', _isAuthorized);
      await prefs.setString('edu_session_state_$userId', _sessionState);
      await prefs.remove('edu_bound_$userId');
    }
    _isBound = _isAuthorized;
    return _isAuthorized;
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
    final oldUserId = _userId;
    clearMemoryForAccountTransition();

    if (oldUserId != null && oldUserId.isNotEmpty) {
      await _clearBoundStatusFor(oldUserId);
    }
  }

  // 绑定教务账号
  Future<bool> bind(
    String studentId,
    String password, {
    required bool eduDataConsentAccepted,
  }) async {
    if (_usingLocalAcademicSession) {
      _errorMessage = '本机模式已阻断服务端教务绑定，请使用本机直连教务';
      notifyListeners();
      return false;
    }
    if (_userId == null) {
      _errorMessage = '用户未登录';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await _authDio.post(
        '/edu/bind',
        data: {
          'student_id': studentId,
          'password': password,
          'edu_data_consent_accepted': eduDataConsentAccepted,
        },
        options: Options(receiveTimeout: _eduLongRequestTimeout),
      );

      _isLoading = false;
      if (response.statusCode == 200) {
        final data = Map<String, dynamic>.from(response.data as Map);
        final token = data['token'];
        final user = data['user'];
        if (token is String && user is Map && _applyAuthPayload != null) {
          await _applyAuthPayload!(token, Map<String, dynamic>.from(user));
        }
        final boundUser = user is Map
            ? Map<String, dynamic>.from(user)
            : const <String, dynamic>{};
        _isAuthorized = boundUser['edu_authorized'] == true;
        _isBound = _isAuthorized;
        _sessionState = boundUser['edu_session_state']?.toString() ?? 'active';
        _studentId = boundUser['edu_student_id']?.toString() ?? studentId;
        _name = boundUser['name']?.toString() ?? '';
        _grade = boundUser['edu_grade']?.toString() ?? '';
        _college = boundUser['edu_college']?.toString() ?? '';
        _major = boundUser['edu_major']?.toString() ?? '';
        _errorMessage = null;
        _statusLoaded = true;
        final boundUserId = _userId!;
        await _saveBoundStatusFor(boundUserId);
        notifyListeners();
        return true;
      }
    } on DioException catch (e) {
      _isLoading = false;
      _errorMessage = _parseDioError(e);
      notifyListeners();
      debugPrint('绑定教务失败: $_errorMessage');
      return false;
    }
    _isLoading = false;
    _errorMessage = '绑定失败，未知错误';
    notifyListeners();
    return false;
  }

  /// 兼容旧页面的“解绑”入口，实际语义是撤销教务授权，稳定学号不会被清空。
  Future<OperationResult<void>> unbind() async {
    return revokeAuthorization();
  }

  Future<OperationResult<void>> logoutSession() async {
    if (_usingLocalAcademicSession) {
      return OperationResult.fail('本机模式已阻断服务端教务操作，请使用本机教务退出');
    }
    if (_userId == null) {
      return OperationResult.fail('用户未登录');
    }
    try {
      final response = await _authDio.post('/edu/session/logout');

      if (response.statusCode == 200) {
        _sessionState = 'logged_out';
        _errorMessage = null;
        _statusLoaded = true;
        await _saveBoundStatusFor(_userId!);
        await _refreshAuthUser?.call();
        notifyListeners();
        return OperationResult.ok(null);
      }
      return OperationResult.fail('退出教务登录失败');
    } on DioException catch (e) {
      final result = _failFromDio(e, '退出教务登录失败');
      debugPrint('退出教务登录失败: ${result.errorMessage}');
      return result;
    }
  }

  Future<OperationResult<void>> resumeSession() async {
    if (_usingLocalAcademicSession) {
      return OperationResult.fail('本机模式已阻断服务端教务操作，请重新登录本机教务');
    }
    if (_userId == null) return OperationResult.fail('用户未登录');
    try {
      final response = await _authDio.post('/edu/session/resume');
      if (response.statusCode == 200) {
        _isAuthorized = response.data['edu_authorized'] != false;
        _isBound = _isAuthorized;
        _sessionState =
            response.data['edu_session_state']?.toString() ?? 'active';
        _errorMessage = null;
        _statusLoaded = true;
        await _saveBoundStatusFor(_userId!);
        await _refreshAuthUser?.call();
        notifyListeners();
        return OperationResult.ok(null);
      }
      return OperationResult.fail('恢复教务会话失败');
    } on DioException catch (error) {
      return _failFromDio(error, '恢复教务会话失败');
    }
  }

  Future<OperationResult<void>> revokeAuthorization() async {
    if (_usingLocalAcademicSession) {
      return OperationResult.fail('本机模式已阻断服务端教务操作，请使用本机教务退出');
    }
    if (_userId == null) return OperationResult.fail('用户未登录');
    final currentUserId = _userId!;
    try {
      final response = await _authDio.delete('/edu/authorization');
      if (response.statusCode == 200 || response.statusCode == 202) {
        _isAuthorized = false;
        _isBound = false;
        _sessionState = 'revoked';
        _errorMessage = null;
        _statusLoaded = true;
        await _saveBoundStatusFor(currentUserId);
        clearGradeCacheForUser(currentUserId);
        try {
          await _clearSensitiveEduSnapshots(currentUserId);
        } catch (error) {
          // 服务端授权已撤销，清理失败不应回滚该安全操作；下次进入时不会再读取该会话。
          debugPrint('清除教务本地敏感快照失败: ${error.runtimeType}');
        }
        await _refreshAuthUser?.call();
        notifyListeners();
        return OperationResult.ok(null);
      }
      return OperationResult.fail('撤销教务授权失败');
    } on DioException catch (error) {
      return _failFromDio(error, '撤销教务授权失败');
    }
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
    if (_usingLocalAcademicSession && localController != null) {
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

    if (!_isBound || requestSourceAccountId.isEmpty) {
      return OperationResult.fail('教务账号未就绪');
    }

    return _runEduRequest(() async {
      try {
        // 调用 Go 服务器，由 Go 使用存储的 cookie 访问教务系统
        final response = await _authDio.post(
          '/edu/courses',
          data: {'year': year, 'semester': semester},
          options: Options(receiveTimeout: _eduLongRequestTimeout),
        );
        if (!isCurrentContext()) {
          return OperationResult.fail('用户已切换');
        }

        if (response.statusCode == 200) {
          final data = response.data;
          final courses = data['courses'];
          final courseCount = courses is List ? courses.length : -1;

          debugPrint(
            'Edu getCourses result: success=${data['success']}, '
            'year=${data['year']}, semester=${data['semester']}, '
            'courses=$courseCount',
          );

          if (courses != null && (courses as List).isNotEmpty) {
            return OperationResult.ok(
              List<Map<String, dynamic>>.from(courses),
            );
          }
          final errorMsg =
              (data['error'] ?? data['message'] ?? data['detail'] ?? '')
                  .toString();
          if (errorMsg.isNotEmpty) {
            return OperationResult.fail(
              errorMsg,
              errorCode: _eduPayloadCode(data),
            );
          }
          if (data['success'] == false) {
            return OperationResult.fail(
              data['message'] ?? '获取课表失败',
              errorCode: _eduPayloadCode(data),
            );
          }
        }
        return OperationResult.fail('获取课表失败');
      } on DioException catch (e) {
        return _failFromDio(e, '获取课表失败');
      }
    });
  }

  /// 获取成绩 — 始终请求网络，返回已解析的 [EduGrade] 列表。
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
    if (_usingLocalAcademicSession &&
        !academicCapabilities.supportsGradeDetail) {
      return OperationResult.fail(
        '本机直连暂不支持成绩构成',
        errorCode: 'LOCAL_FEATURE_NOT_SUPPORTED',
      );
    }
    final requestUserId = _userId;
    if (requestUserId == null) {
      return OperationResult.fail('用户未登录');
    }
    final requestSourceAccountId = _studentId.trim();
    final requestSourceKind = _activeAcademicSourceKind;
    if (requestSourceAccountId.isEmpty) {
      return OperationResult.fail('教务账号未就绪');
    }

    final cacheKey = _gradeDetailCacheKey(grade, year, semester);

    if (!forceRefresh) {
      final cached = _gradeDetailCache[cacheKey];
      if (cached != null) {
        return OperationResult.ok(cached);
      }
    }

    if (grade.classId.isEmpty) {
      return OperationResult.fail('缺少教学班信息，暂不能获取成绩构成');
    }

    final pending = _gradeDetailRequests[cacheKey];
    if (pending != null) return pending;

    Future<Response<dynamic>> request() {
      return _authDio.post(
        '/edu/grades/detail',
        data: {
          'year': year,
          'semester': semester,
          'class_id': grade.classId,
          'course_name': grade.name,
          'course_id': grade.courseId.isNotEmpty ? grade.courseId : null,
          'student_grade_id':
              grade.studentGradeId.isNotEmpty ? grade.studentGradeId : null,
        },
        options: Options(receiveTimeout: _eduLongRequestTimeout),
      );
    }

    late final Future<OperationResult<EduGradeDetail>> requestFuture;
    requestFuture = _runEduRequest<OperationResult<EduGradeDetail>>(() async {
      try {
        final response = await request();
        if (!_isSameAcademicContext(
          requestUserId,
          requestSourceAccountId,
          requestSourceKind,
        )) {
          return OperationResult.fail('用户已切换');
        }
        if (response.statusCode == 200) {
          final detail = EduGradeDetail.fromJson(
            Map<String, dynamic>.from(response.data),
          );
          if (detail.success && detail.components.isNotEmpty) {
            _gradeDetailCache[cacheKey] = detail;
          }
          return OperationResult.ok(detail);
        }
        return OperationResult.fail('获取成绩构成失败');
      } on DioException catch (e) {
        return _failFromDio(e, '获取成绩构成失败');
      }
    }).whenComplete(() {
      if (identical(_gradeDetailRequests[cacheKey], requestFuture)) {
        _gradeDetailRequests.remove(cacheKey);
      }
    });
    _gradeDetailRequests[cacheKey] = requestFuture;
    return requestFuture;
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
    if (_usingLocalAcademicSession &&
        !academicCapabilities.supportsGradeDetail) {
      return Future<void>.value();
    }
    final requestUserId = _userId;
    final requestSourceAccountId = _studentId.trim();
    final requestSourceKind = _activeAcademicSourceKind;
    if (requestUserId == null ||
        requestSourceAccountId.isEmpty ||
        grades.isEmpty) {
      return Future<void>.value();
    }

    final pendingGrades = grades
        .where(
          (grade) =>
              grade.classId.isNotEmpty &&
              getCachedGradeDetail(grade, year, semester) == null,
        )
        .toList(growable: false);
    if (pendingGrades.isEmpty) return Future<void>.value();

    final jobKey = '$requestUserId|${requestSourceKind.name}|'
        '$requestSourceAccountId|$year|$semester';
    final activeJob = _gradeDetailPrefetchJobs[jobKey];
    if (activeJob != null) return activeJob;

    late final Future<void> job;
    job = _runGradeDetailPrefetch(
      requestUserId: requestUserId,
      requestSourceAccountId: requestSourceAccountId,
      requestSourceKind: requestSourceKind,
      grades: pendingGrades,
      year: year,
      semester: semester,
      initialDelay: initialDelay,
    ).whenComplete(() {
      if (identical(_gradeDetailPrefetchJobs[jobKey], job)) {
        _gradeDetailPrefetchJobs.remove(jobKey);
      }
    });
    _gradeDetailPrefetchJobs[jobKey] = job;
    return job;
  }

  Future<void> _runGradeDetailPrefetch({
    required String requestUserId,
    required String requestSourceAccountId,
    required AcademicSourceKind requestSourceKind,
    required List<EduGrade> grades,
    required String year,
    required int semester,
    required Duration initialDelay,
  }) async {
    if (initialDelay > Duration.zero) await Future<void>.delayed(initialDelay);

    for (final grade in grades) {
      if (!_isSameAcademicContext(
        requestUserId,
        requestSourceAccountId,
        requestSourceKind,
      )) {
        return;
      }
      if (grade.classId.isEmpty ||
          getCachedGradeDetail(grade, year, semester) != null) {
        continue;
      }

      await fetchGradeDetail(grade, year, semester);
      if (!_isSameAcademicContext(
        requestUserId,
        requestSourceAccountId,
        requestSourceKind,
      )) {
        return;
      }

      // 给详情点击、刷新等前台请求留出抢占窗口。
      await Future<void>.delayed(const Duration(milliseconds: 160));
    }
  }

  Future<OperationResult<EduAcademicSituation>> fetchAcademicSituation() async {
    if (_usingLocalAcademicSession &&
        !academicCapabilities.supportsAcademicSituation) {
      return OperationResult.fail(
        '本机直连暂不支持官方 GPA',
        errorCode: 'LOCAL_FEATURE_NOT_SUPPORTED',
      );
    }
    final requestUserId = _userId;
    if (requestUserId == null) {
      return OperationResult.fail('用户未登录');
    }
    final requestSourceAccountId = _studentId.trim();
    final requestSourceKind = _activeAcademicSourceKind;

    Future<Response<dynamic>> request() {
      return _authDio.post(
        '/edu/academic-situation',
        data: const <String, dynamic>{},
        options: Options(receiveTimeout: _eduLongRequestTimeout),
      );
    }

    return _runEduRequest(() async {
      try {
        final response = await request();
        if (!_isSameAcademicContext(
          requestUserId,
          requestSourceAccountId,
          requestSourceKind,
        )) {
          return OperationResult.fail('用户已切换');
        }
        if (response.statusCode == 200) {
          if (response.data is! Map) {
            return OperationResult.fail('获取学业情况失败');
          }
          final rawSituation = Map<String, dynamic>.from(response.data as Map);
          final situation = EduAcademicSituation.fromJson(
            rawSituation,
          );
          if (!situation.success) {
            return OperationResult.fail(
              situation.message ?? '获取学业情况失败',
              errorCode: _eduPayloadCode(rawSituation),
            );
          }
          final persisted = await _persistAcademicSituation(
            appUserId: requestUserId,
            sourceAccountId: requestSourceAccountId,
            sourceKind: requestSourceKind,
            raw: rawSituation,
          );
          if (!persisted) {
            return OperationResult.fail(
              '学业情况本地加密保存失败，请稍后重试',
              errorCode: 'local_storage_failed',
            );
          }
          _academicSituationCache[_academicSituationCacheKey(
            requestUserId,
            requestSourceAccountId,
            requestSourceKind,
          )] = AcademicSituationCacheEntry(
            data: situation,
            updatedAt: DateTime.now(),
          );
          return OperationResult.ok(situation);
        }
        return OperationResult.fail('获取学业情况失败');
      } on DioException catch (e) {
        return _failFromDio(e, '获取学业情况失败');
      }
    });
  }

  Future<bool> _persistAcademicSituation({
    required String appUserId,
    required String sourceAccountId,
    required AcademicSourceKind sourceKind,
    required Map<String, dynamic> raw,
  }) async {
    final store = _academicCacheStoreFor(
      appUserId: appUserId,
      sourceAccountId: sourceAccountId,
    );
    if (store == null) {
      return _isSameAcademicContext(appUserId, sourceAccountId, sourceKind);
    }
    try {
      await store.writeAcademicSituation(data: raw);
      return _isSameAcademicContext(appUserId, sourceAccountId, sourceKind);
    } catch (error) {
      // 页面保留本次网络响应，但 AI 侧不会获得未落入保险箱的数据。
      debugPrint('保存加密学业情况失败: ${error.runtimeType}');
      return false;
    }
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
    if (_usingLocalAcademicSession && localController != null) {
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

    return _runEduRequest(() async {
      try {
        // 调用 Go 服务器，由 Go 使用存储的 cookie 访问教务系统
        final response = await _authDio.post(
          '/edu/grades',
          data: {'year': year, 'semester': semester},
          options: Options(receiveTimeout: _eduLongRequestTimeout),
        );

        if (response.statusCode == 200) {
          final data = response.data;
          if (data['grades'] != null) {
            return OperationResult.ok(
              List<Map<String, dynamic>>.from(data['grades']),
            );
          }
          if (data['error'] != null) {
            return OperationResult.fail(
              data['error'].toString(),
              errorCode: _eduPayloadCode(data),
            );
          }
        }
        return OperationResult.fail('获取成绩失败');
      } on DioException catch (e) {
        return _failFromDio(e, '获取成绩失败');
      }
    });
  }

  Future<OperationResult<EduCreditRequirementOverview>>
      fetchCreditRequirements() async {
    if (_usingLocalAcademicSession &&
        !academicCapabilities.supportsCreditRequirements) {
      return OperationResult.fail(
        '本机直连暂不支持学分要求',
        errorCode: 'LOCAL_FEATURE_NOT_SUPPORTED',
      );
    }
    final requestUserId = _userId;
    if (requestUserId == null) {
      return OperationResult.fail('用户未登录');
    }
    final requestSourceAccountId = _studentId.trim();
    final requestSourceKind = _activeAcademicSourceKind;

    return _runEduRequest(() async {
      try {
        final response = await _authDio.post(
          '/edu/credit-requirements',
          data: const <String, dynamic>{},
          options: Options(receiveTimeout: _eduLongRequestTimeout),
        );
        if (!_isSameAcademicContext(
          requestUserId,
          requestSourceAccountId,
          requestSourceKind,
        )) {
          return OperationResult.fail('用户已切换');
        }
        if (response.statusCode == 200) {
          if (response.data is! Map) {
            return OperationResult.fail('获取学分要求失败');
          }
          final raw = Map<String, dynamic>.from(response.data as Map);
          final overview = EduCreditRequirementOverview.fromJson(raw);
          if (!overview.success) {
            return OperationResult.fail(
              overview.message ?? '获取学分要求失败',
              errorCode: _eduPayloadCode(raw),
            );
          }
          // 持久化到 AES-GCM 保险箱
          final store = _academicCacheStoreFor(
            appUserId: requestUserId,
            sourceAccountId: requestSourceAccountId,
          );
          if (store != null) {
            try {
              await store.writeCreditRequirements(
                data: raw,
                fetchedAt: overview.capturedAt ?? DateTime.now(),
              );
            } catch (error) {
              debugPrint('保存加密学分要求失败: ${error.runtimeType}');
              return OperationResult.fail(
                '学分要求已获取，但本地加密保存失败',
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
          _creditRequirementCache[_creditRequirementCacheKey(
            requestUserId,
            requestSourceAccountId,
            requestSourceKind,
          )] = CreditRequirementCacheEntry(
            data: overview,
            updatedAt: DateTime.now(),
          );
          return OperationResult.ok(overview);
        }
        return OperationResult.fail('获取学分要求失败');
      } on DioException catch (e) {
        return _failFromDio(e, '获取学分要求失败');
      }
    });
  }

  @override
  void dispose() {
    _academicSessionController?.removeListener(_onAcademicSessionChanged);
    super.dispose();
  }
}
