import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../contracts/reminder_notification_client.dart';

/// macOS 课程提醒实现。
///
/// macOS 使用 Darwin 原生通知接口，不能复用 Android client 的初始化、权限
/// 或通知详情配置；课程排程仍由上层服务统一计算，客户端只负责平台投递。
class DarwinReminderNotificationClient implements ReminderNotificationClient {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  @override
  Future<void> initializeCourseReminders() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    } catch (_) {
      // 系统时区数据库异常时保留插件默认时区，避免启动阶段崩溃。
    }

    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      defaultPresentSound: false,
    );

    await _plugin.initialize(const InitializationSettings(macOS: darwin));
    _initialized = true;
  }

  @override
  Future<bool> requestCourseReminderPermissions() async {
    await initializeCourseReminders();
    final macOSPlugin = _plugin.resolvePlatformSpecificImplementation<
        MacOSFlutterLocalNotificationsPlugin>();
    if (macOSPlugin == null) return false;

    final granted = await macOSPlugin.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );
    return granted ?? false;
  }

  @override
  Future<bool> scheduleCourseReminder({
    required int id,
    required String title,
    required String body,
    required String detailText,
    required DateTime scheduledTime,
    required DateTime classStart,
    required String payload,
    required String ticker,
    required bool exactAllowWhileIdle,
  }) async {
    await initializeCourseReminders();

    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(scheduledTime, tz.local),
        NotificationDetails(macOS: _courseNotificationDetails(detailText)),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
      return true;
    } catch (error) {
      debugPrint('macOS 课程提醒排程失败: $error');
      return false;
    }
  }

  @override
  Future<void> cancelCourseReminder(int id) async {
    await _plugin.cancel(id);
  }

  @override
  Future<bool> scheduleCalendarReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    required String payload,
  }) async {
    await initializeCourseReminders();

    try {
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(scheduledTime, tz.local),
        const NotificationDetails(
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: false,
            interruptionLevel: InterruptionLevel.active,
            threadIdentifier: 'calendar_reminders',
          ),
        ),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
      return true;
    } catch (error) {
      debugPrint('macOS 日历提醒排程失败: $error');
      return false;
    }
  }

  @override
  Future<void> cancelCalendarReminder(int id) async {
    await _plugin.cancel(id);
  }

  DarwinNotificationDetails _courseNotificationDetails(String detailText) {
    return DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentList: true,
      presentSound: false,
      subtitle: _teacherFrom(detailText),
      interruptionLevel: InterruptionLevel.active,
      threadIdentifier: 'course_reminders',
    );
  }

  String? _teacherFrom(String detailText) {
    for (final line in detailText.split('\n')) {
      if (line.startsWith('教师：')) {
        final teacher = line.substring('教师：'.length).trim();
        return teacher.isEmpty ? null : teacher;
      }
    }
    return null;
  }
}
