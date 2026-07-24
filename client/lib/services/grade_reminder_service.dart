import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/contracts/reminder_notification_client.dart';

import '../config/api_constants.dart';
import '../models/edu_grade.dart';
import '../models/grade_reminder_snapshot.dart';
import '../models/grade_reminder_status.dart';
import '../platform/app_platform.dart';
import 'keep_alive_service.dart';

class GradeReminderService {
  GradeReminderService._();

  static final GradeReminderService instance = GradeReminderService._();

  static const MethodChannel _channel = MethodChannel(
    'shenliyuan/grade_reminders',
  );

  bool _notificationsInitialized = false;

  /// 使用构建目标而非 Flutter 运行时平台；OHOS Flutter 当前会报告 Android。
  bool get _isAndroid => AppPlatforms.current.isAndroid;

  Future<GradeReminderStatus> getStatus({String? userId}) async {
    if (!_isAndroid) return const GradeReminderStatus.unsupported();
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getGradeReminderStatus',
        {'userId': userId},
      );
      return GradeReminderStatus.fromMap(result);
    } catch (e) {
      debugPrint('读取成绩提醒状态失败: $e');
      return const GradeReminderStatus.unsupported();
    }
  }

  Future<bool> isEnabled({required String userId}) async {
    return (await getStatus(userId: userId)).enabled;
  }

  Future<void> syncRuntimeConfig({required String? userId}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('syncGradeReminderConfig', {
        'userId': userId,
        'apiBaseUrl': ApiConstants.baseUrl,
      });
    } catch (e) {
      debugPrint('同步成绩提醒运行配置失败: $e');
    }
  }

  /// 确保后台周期检查任务仍在调度中（check-then-enqueue）。
  /// 只在任务不存在/未排队时补建，不重置正在排队的周期计时器。
  Future<void> ensureScheduledIfEnabled() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('ensureGradeReminderScheduled');
    } catch (e) {
      debugPrint('确认成绩提醒后台任务失败: $e');
    }
  }

  /// 立即触发一次成绩检查（OneTimeWorkRequest），用于调试/手动验证后台逻辑。
  Future<void> runCheckNow() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('runGradeReminderCheckNow');
    } catch (e) {
      debugPrint('立即检查成绩更新失败: $e');
    }
  }

  Future<GradeReminderStatus> setEnabled({
    required bool enabled,
    required String userId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
  }) async {
    if (!_isAndroid) return const GradeReminderStatus.unsupported();

    await syncRuntimeConfig(userId: userId);
    var permissionGranted = true;
    if (enabled) {
      await KeepAliveService.instance.setEnabled(true);
      permissionGranted = await requestNotificationPermission();
    }

    final snapshot = enabled
        ? GradeReminderSnapshot.initialBaseline(grades)
        : GradeReminderSnapshot.fromGrades(grades);
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'setGradeReminderEnabled',
        {
          'enabled': enabled && permissionGranted,
          'userId': userId,
          'apiBaseUrl': ApiConstants.baseUrl,
          'year': year,
          'semester': semester,
          'snapshot': snapshot.toJson(),
          'notificationGranted': permissionGranted,
        },
      );
      return GradeReminderStatus.fromMap(result);
    } catch (e) {
      debugPrint('设置成绩提醒失败: $e');
      return const GradeReminderStatus.unsupported();
    }
  }

  Future<void> syncBaselineIfEnabled({
    required String userId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
  }) async {
    if (!_isAndroid) return;
    final status = await getStatus(userId: userId);
    if (!status.enabled) return;
    await syncBaseline(
      userId: userId,
      year: year,
      semester: semester,
      grades: grades,
    );
  }

  Future<void> syncBaseline({
    required String userId,
    required String year,
    required int semester,
    required List<EduGrade> grades,
  }) async {
    if (!_isAndroid) return;
    final snapshot = GradeReminderSnapshot.fromGrades(grades);
    try {
      await _channel.invokeMethod<void>('syncGradeReminderBaseline', {
        'userId': userId,
        'year': year,
        'semester': semester,
        'snapshot': snapshot.toJson(),
      });
    } catch (e) {
      debugPrint('同步成绩提醒基线失败: $e');
    }
  }

  Future<void> syncSelectedSemester({
    required String userId,
    required String year,
    required int semester,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('syncGradeReminderConfig', {
        'userId': userId,
        'apiBaseUrl': ApiConstants.baseUrl,
        'year': year,
        'semester': semester,
      });
    } catch (e) {
      debugPrint('同步成绩提醒目标学期失败: $e');
    }
  }

  Future<void> clearForUser(String userId) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('clearGradeReminderForUser', {
        'userId': userId,
      });
    } catch (e) {
      debugPrint('清理成绩提醒失败: $e');
    }
  }

  Future<void> clearGradeUpdateNotifications() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('clearGradeUpdateNotifications');
    } catch (e) {
      debugPrint('清理历史成绩通知失败: $e');
    }
  }

  Future<bool> openNotificationSettings() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'openGradeNotificationSettings',
          ) ??
          false;
    } catch (e) {
      debugPrint('打开成绩提醒通知设置失败: $e');
      return false;
    }
  }

  Future<bool> openKeepAliveSettings() {
    return KeepAliveService.instance.openSettings();
  }

  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    await _ensureNotificationsInitialized();
    return await ReminderNotificationClient.instance.requestGradeReminderPermissions();
  }

  Future<void> _ensureNotificationsInitialized() async {
    if (_notificationsInitialized) return;
    await ReminderNotificationClient.instance.initializeGradeReminders();
    _notificationsInitialized = true;
  }
}
