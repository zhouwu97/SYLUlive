import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import '../contracts/reminder_notification_client.dart';

class AndroidReminderNotificationClient implements ReminderNotificationClient {
  static const String _courseChannelId = 'course_reminders_silent';
  static const String _courseChannelName = '课程提醒';
  
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  @override
  Future<void> initializeCourseReminders() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      defaultPresentSound: false,
    );
    const settings = InitializationSettings(android: android, iOS: darwin);

    await _plugin.initialize(settings);
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
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
    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      if (androidPlugin == null) return false;

      final bool? notiGranted = await androidPlugin.requestNotificationsPermission();
      final bool? alarmGranted = await androidPlugin.requestExactAlarmsPermission();

      debugPrint('通知权限: $notiGranted, 精确闹钟权限: $alarmGranted');
      return (notiGranted ?? false) && (alarmGranted ?? false);
    } else if (Platform.isIOS) {
      final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();

      final bool? iosGranted = await iosPlugin?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return iosGranted ?? false;
    }
    return true;
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
      final mode = exactAllowWhileIdle 
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
        androidScheduleMode: mode,
        payload: payload,
      );
      return true;
    } catch (e) {
      debugPrint('课程提醒排程失败[$exactAllowWhileIdle]: $e');
      return false;
    }
  }

  @override
  Future<void> cancelCourseReminder(int id) async {
    await _plugin.cancel(id);
  }

  @override
  Future<void> initializeGradeReminders() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings);
  }

  @override
  Future<bool> requestGradeReminderPermissions() async {
    if (!Platform.isAndroid) return true;
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return false;
    return await androidPlugin.requestNotificationsPermission() ?? false;
  }

  NotificationDetails _courseNotificationDetails(
      String title, String detailText, String ticker, DateTime classStart) {
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
        colorized: false,
        subText: '课前静音提醒',
        when: classStart.millisecondsSinceEpoch,
        usesChronometer: true,
        chronometerCountDown: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentList: true,
        presentSound: false,
        interruptionLevel: InterruptionLevel.active,
        threadIdentifier: 'course_reminders',
      ),
    );
  }
}
