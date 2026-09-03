import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../app_platform.dart';
import '../contracts/reminder_notification_client.dart';

/// 课程、成绩和日历提醒的跨平台实现。
///
/// Android 的 exact alarm / ongoing 只存在于 Android 分支；iOS 使用
/// UserNotifications 的定时通知，不模拟 Android 的常驻能力。
class LocalReminderNotificationClient implements ReminderNotificationClient {
  static const _courseChannelId = 'course_reminders_silent';
  static const _courseChannelName = '课程提醒';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  @override
  Future<void> initializeCourseReminders() async {
    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    } catch (_) {}

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
        defaultPresentSound: false,
      ),
    );
    await _plugin.initialize(settings);
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _courseChannelId,
            _courseChannelName,
            description: '上课前 5 分钟静音提醒',
            importance: Importance.defaultImportance,
            playSound: false,
            enableVibration: false,
          ),
        );
  }

  @override
  Future<bool> requestCourseReminderPermissions() async {
    if (AppPlatforms.current.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return false;
      final granted = await android.requestNotificationsPermission();
      final exact = await android.requestExactAlarmsPermission();
      debugPrint('通知权限: $granted, 精确闹钟权限: $exact');
      return (granted ?? false) && (exact ?? false);
    }
    if (AppPlatforms.current.isIOS) {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(
              alert: true, badge: true, sound: true) ??
          false;
    }
    return false;
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
    try {
      final androidMode = exactAllowWhileIdle
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle;
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(scheduledTime, tz.local),
        _courseNotificationDetails(title, detailText, ticker, classStart),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: androidMode,
        payload: payload,
      );
      return true;
    } catch (error) {
      debugPrint('课程提醒排程失败[$exactAllowWhileIdle]: $error');
      return false;
    }
  }

  @override
  Future<void> cancelCourseReminder(int id) => _plugin.cancel(id);

  @override
  Future<bool> showGradeUpdate({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    try {
      await initializeCourseReminders();
      await _plugin.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _courseChannelId,
            _courseChannelName,
            channelDescription: '本机成绩更新提醒',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            playSound: false,
            enableVibration: false,
            silent: true,
            autoCancel: true,
            category: AndroidNotificationCategory.reminder,
            visibility: NotificationVisibility.public,
            subText: '成绩更新',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: false,
            threadIdentifier: 'grade_updates',
          ),
        ),
        payload: payload,
      );
      return true;
    } catch (error) {
      debugPrint('成绩更新通知失败: $error');
      return false;
    }
  }

  @override
  Future<bool> scheduleCalendarReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    required String payload,
  }) async {
    try {
      await initializeCourseReminders();
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(scheduledTime, tz.local),
        _calendarNotificationDetails(),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
      return true;
    } catch (error) {
      debugPrint('日历提醒排程失败: $error');
      return false;
    }
  }

  @override
  Future<void> cancelCalendarReminder(int id) => _plugin.cancel(id);

  NotificationDetails _courseNotificationDetails(
    String title,
    String detailText,
    String ticker,
    DateTime classStart,
  ) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _courseChannelId,
        _courseChannelName,
        channelDescription: '上课前 5 分钟静音提醒',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        styleInformation: BigTextStyleInformation(
          detailText,
          contentTitle: title,
          summaryText: '静音提醒 · 即将上课',
        ),
        playSound: false,
        enableVibration: false,
        silent: true,
        autoCancel: false,
        ongoing: true,
        onlyAlertOnce: true,
        timeoutAfter: const Duration(minutes: 6).inMilliseconds,
        ticker: ticker,
        category: AndroidNotificationCategory.reminder,
        visibility: NotificationVisibility.public,
        color: const Color(0xFF4F46E5),
        subText: '课前静音提醒',
        when: classStart.millisecondsSinceEpoch,
        usesChronometer: true,
        chronometerCountDown: true,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentList: true,
        presentSound: false,
        threadIdentifier: 'course_reminders',
      ),
    );
  }

  NotificationDetails _calendarNotificationDetails() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _courseChannelId,
        _courseChannelName,
        channelDescription: '个人日历提醒',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        playSound: false,
        enableVibration: false,
        silent: true,
        autoCancel: true,
        onlyAlertOnce: true,
        category: AndroidNotificationCategory.reminder,
        visibility: NotificationVisibility.public,
        subText: '日历提醒',
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentList: true,
        presentSound: false,
        threadIdentifier: 'calendar_reminders',
      ),
    );
  }
}
