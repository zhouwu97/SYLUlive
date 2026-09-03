import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/data/mapper/raw_grade_mapper.dart';
import '../features/campus_data/storage/academic_cache_store.dart';
import '../models/edu_grade.dart';
import '../models/grade_reminder_snapshot.dart';
import '../models/grade_reminder_status.dart';
import '../platform/contracts/preferences_store.dart';
import '../platform/contracts/reminder_notification_client.dart';
import '../utils/edu_semester_utils.dart';

/// 成绩提醒只在 App 前台恢复时执行，教务请求始终由本机会话直连学校。
///
/// 旧版 Android 后台 Worker 已退役；这里不创建定时任务，也不把成绩或
/// 教务凭据写入普通偏好设置。成绩基线复用 AES-GCM 学业保险箱。
class GradeReminderService {
  GradeReminderService._({
    AcademicSessionController? controller,
    AccountScopedAcademicCacheBuilder? cacheStoreBuilder,
    ReminderNotificationClient? notificationClient,
    Future<AppPreferencesStore> Function()? preferencesLoader,
    DateTime Function()? now,
  })  : _controller = controller,
        _cacheStoreBuilder = cacheStoreBuilder,
        _notificationClient = notificationClient,
        _preferencesLoader =
            preferencesLoader ?? AppPreferencesStore.getInstance,
        _now = now ?? DateTime.now;

  static final GradeReminderService instance = GradeReminderService._();

  @visibleForTesting
  GradeReminderService.test({
    AcademicSessionController? controller,
    AccountScopedAcademicCacheBuilder? cacheStoreBuilder,
    ReminderNotificationClient? notificationClient,
    Future<AppPreferencesStore> Function()? preferencesLoader,
    DateTime Function()? now,
  }) : this._(
          controller: controller,
          cacheStoreBuilder: cacheStoreBuilder,
          notificationClient: notificationClient,
          preferencesLoader: preferencesLoader,
          now: now,
        );

  AcademicSessionController? _controller;
  final AccountScopedAcademicCacheBuilder? _cacheStoreBuilder;
  final ReminderNotificationClient? _notificationClient;
  final Future<AppPreferencesStore> Function() _preferencesLoader;
  final DateTime Function() _now;
  Future<void>? _runningCheck;

  /// 由恢复协调器绑定当前会话；账号切换时会覆盖旧引用。
  void bindController(AcademicSessionController controller) {
    _controller = controller;
  }

  ReminderNotificationClient get _notifications =>
      _notificationClient ?? ReminderNotificationClient.instance;

  Future<GradeReminderStatus> getStatus({String? userId}) async {
    final normalized = _normalize(userId);
    if (normalized == null) return const GradeReminderStatus.unsupported();
    final prefs = await _preferencesLoader();
    final enabled = prefs.getBool(_enabledKey(normalized)) ?? false;
    final term = _termFromValue(prefs.getString(_termKey(normalized)));
    return GradeReminderStatus(
      supported: true,
      enabled: enabled,
      state: enabled ? 'foreground_only' : 'off',
      notificationGranted: true,
      backgroundReady: false,
      needAction:
          enabled && _controller?.isAuthenticated != true ? 'login' : null,
      year: term?.year,
      semester: term?.semester,
      lastCheckAt: _dateFromMillis(prefs.getInt(_lastCheckKey(normalized))),
      lastSuccessAt: _dateFromMillis(prefs.getInt(_lastSuccessKey(normalized))),
      consecutiveFailures: prefs.getInt(_failureKey(normalized)) ?? 0,
    );
  }

  Future<bool> isEnabled({required String userId}) async {
    final prefs = await _preferencesLoader();
    return prefs.getBool(_enabledKey(userId)) ?? false;
  }

  Future<void> syncRuntimeConfig({required String? userId}) async {}

  /// 保留旧 API 外观；新版本不再创建 WorkManager 或其它后台任务。
  Future<void> ensureScheduledIfEnabled() async {}

  /// 在前台恢复时检查当前学期，整个链路不使用共享 App API Dio。
  Future<void> runCheckNow({AcademicSessionController? controller}) async {
    final active = controller ?? _controller;
    if (active == null || _runningCheck != null) return;
    _controller = active;
    final future = _runCheck(active);
    _runningCheck = future;
    try {
      await future;
    } finally {
      if (identical(_runningCheck, future)) _runningCheck = null;
    }
  }

  Future<GradeReminderStatus> setEnabled({
    required bool enabled,
    required String userId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
  }) async {
    final normalized = _normalize(userId);
    if (normalized == null) return const GradeReminderStatus.unsupported();
    final prefs = await _preferencesLoader();
    if (enabled) {
      await syncBaseline(
        userId: normalized,
        year: year,
        semester: semester,
        grades: grades,
      );
      await prefs.setString(_termKey(normalized), '${year.trim()}_$semester');
    }
    await prefs.setBool(_enabledKey(normalized), enabled);
    if (!enabled) await prefs.remove(_failureKey(normalized));
    return getStatus(userId: normalized);
  }

  Future<void> syncBaselineIfEnabled({
    required String userId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
  }) async {
    if (await isEnabled(userId: userId)) {
      await syncBaseline(
        userId: userId,
        year: year,
        semester: semester,
        grades: grades,
      );
    }
  }

  /// 将页面已有的本机成绩写入加密保险箱，供后续前台检查比较。
  Future<void> syncBaseline({
    required String userId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
  }) async {
    final sourceAccountId = _controller?.studentId?.trim() ?? '';
    if (sourceAccountId.isEmpty) return;
    final store = _cacheStore(userId, sourceAccountId);
    await store?.writeGrades(
      year: year,
      semester: semester,
      grades: grades.map(_gradeToJson).toList(growable: false),
      fetchedAt: _now().toUtc(),
    );
  }

  Future<void> syncSelectedSemester({
    required String userId,
    required String year,
    required int semester,
  }) async {
    final controller = _controller;
    if (controller == null || !controller.isAuthenticated) return;
    final result = await controller.loadGrades(year: year, semester: semester);
    if (result == null) return;
    final rawGrades =
        result.grades.map(RawGradeMapper.toAppJson).toList(growable: false);
    await _checkAndPersist(
      controller,
      userId: userId,
      studentId: controller.studentId?.trim() ?? '',
      year: year,
      semester: semester,
      grades: rawGrades.map(EduGrade.fromJson).toList(growable: false),
      rawGrades: rawGrades,
    );
  }

  Future<void> clearForUser(String userId) async {
    final normalized = _normalize(userId);
    if (normalized == null) return;
    final prefs = await _preferencesLoader();
    for (final key in <String>[
      _enabledKey(normalized),
      _termKey(normalized),
      _lastCheckKey(normalized),
      _lastSuccessKey(normalized),
      _failureKey(normalized),
    ]) {
      await prefs.remove(key);
    }
  }

  Future<void> clearGradeUpdateNotifications() async {}

  Future<bool> openNotificationSettings() async => false;

  Future<bool> openKeepAliveSettings() async => false;

  Future<bool> requestNotificationPermission() async {
    await _notifications.initializeCourseReminders();
    return _notifications.requestCourseReminderPermissions();
  }

  Future<void> _runCheck(AcademicSessionController controller) async {
    final userId = _normalize(controller.appUserId);
    final studentId = controller.studentId?.trim() ?? '';
    if (userId == null || studentId.isEmpty || !controller.isAuthenticated) {
      return;
    }
    final prefs = await _preferencesLoader();
    // 只有用户明确开启提醒时才访问教务，避免前台恢复变成隐式刷新。
    if (prefs.getBool(_enabledKey(userId)) != true) return;
    final term = _termFromValue(prefs.getString(_termKey(userId))) ??
        EduSemester.current();
    await prefs.setInt(_lastCheckKey(userId), _now().millisecondsSinceEpoch);
    final result = await controller.loadGrades(
      year: term.year,
      semester: term.semester,
    );
    if (result == null) {
      final failures = prefs.getInt(_failureKey(userId)) ?? 0;
      await prefs.setInt(_failureKey(userId), failures + 1);
      return;
    }
    final rawGrades =
        result.grades.map(RawGradeMapper.toAppJson).toList(growable: false);
    await _checkAndPersist(
      controller,
      userId: userId,
      studentId: studentId,
      year: term.year,
      semester: term.semester,
      grades: rawGrades.map(EduGrade.fromJson).toList(growable: false),
      rawGrades: rawGrades,
    );
    await prefs.setInt(_lastSuccessKey(userId), _now().millisecondsSinceEpoch);
    await prefs.setInt(_failureKey(userId), 0);
  }

  Future<void> _checkAndPersist(
    AcademicSessionController controller, {
    required String userId,
    required String studentId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
    required List<Map<String, dynamic>> rawGrades,
  }) async {
    if (studentId.isEmpty) return;
    final store = _cacheStore(userId, studentId);
    if (store == null) return;
    final old = (await store.readSnapshot())?.terms['${year.trim()}_$semester'];
    final oldSnapshot = old == null
        ? null
        : GradeReminderSnapshot.fromGrades(
            old.grades.map(EduGrade.fromJson).toList(growable: false),
            updatedAt: old.fetchedAt,
          );
    final next = GradeReminderSnapshot.fromGrades(grades, updatedAt: _now());
    final diff = next.diffFrom(oldSnapshot);
    await store.writeGrades(
      year: year,
      semester: semester,
      grades: rawGrades,
      fetchedAt: _now().toUtc(),
    );
    if (!diff.hasChanges || diff.baselineOnly) return;

    final body =
        diff.changes.take(3).map((change) => change.summary).join('\n');
    final suffix =
        diff.changes.length > 3 ? '\n还有 ${diff.changes.length - 3} 门课程' : '';
    await _notifications.showGradeUpdate(
      id: _notificationId(userId, studentId, year, semester, diff.changeHash),
      title: '教务成绩有更新',
      body: '$body$suffix',
      payload: jsonEncode(<String, dynamic>{
        'type': 'grade_update',
        'user_id': userId,
        'student_id': studentId,
        'year': year,
        'semester': semester,
      }),
    );
  }

  AcademicCacheStore? _cacheStore(String userId, String studentId) {
    if (userId.trim().isEmpty || studentId.trim().isEmpty) return null;
    return _cacheStoreBuilder?.call(userId, studentId) ??
        AcademicCacheStore(appUserId: userId, sourceAccountId: studentId);
  }

  static Map<String, dynamic> _gradeToJson(EduGrade grade) => <String, dynamic>{
        'name': grade.name,
        'class_id': grade.classId,
        'student_grade_id': grade.studentGradeId,
        'course_id': grade.courseId,
        'course_code': grade.courseCode,
        'grade': grade.displayGrade,
        'credits': grade.credits,
        'gpa': grade.gpa,
        'teacher': grade.teacher,
        'grade_points': grade.gradePoints,
        'fraction': grade.fraction,
        'exam_type': grade.examType,
        'course_category': grade.courseCategory,
        'assessment_method': grade.assessmentMethod,
        'is_degree': grade.isDegree,
      };

  static String? _normalize(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static ({String year, int semester})? _termFromValue(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^(.+)_([0-9]+)$').firstMatch(value.trim());
    final semester = int.tryParse(match?.group(2) ?? '');
    final year = match?.group(1)?.trim() ?? '';
    if (year.isEmpty || semester == null || !EduSemester.isValid(semester)) {
      return null;
    }
    return (year: year, semester: semester);
  }

  static DateTime? _dateFromMillis(int? value) {
    if (value == null || value <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(value);
  }

  static int _notificationId(
    String userId,
    String studentId,
    String year,
    int semester,
    String hash,
  ) {
    var value =
        Object.hash(userId, studentId, year, semester, hash) & 0x7fffffff;
    if (value == 0) value = 1;
    return value;
  }

  static String _enabledKey(String userId) => 'grade_reminder_enabled_$userId';
  static String _termKey(String userId) => 'grade_reminder_term_$userId';
  static String _lastCheckKey(String userId) =>
      'grade_reminder_last_check_$userId';
  static String _lastSuccessKey(String userId) =>
      'grade_reminder_last_success_$userId';
  static String _failureKey(String userId) => 'grade_reminder_failures_$userId';
}

typedef AccountScopedAcademicCacheBuilder = AcademicCacheStore Function(
  String appUserId,
  String sourceAccountId,
);
