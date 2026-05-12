import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../providers/course_schedule_provider.dart';

class CourseReminderResult {
  final bool enabled;
  final bool permissionGranted;
  final int scheduledCount;
  final String message;

  const CourseReminderResult({
    required this.enabled,
    required this.permissionGranted,
    required this.scheduledCount,
    required this.message,
  });
}

class CourseBackgroundKeepAliveStatus {
  final bool supported;
  final bool isIgnoringBatteryOptimizations;
  final bool canScheduleExactAlarms;
  final String manufacturer;
  final int sdkInt;

  const CourseBackgroundKeepAliveStatus({
    required this.supported,
    required this.isIgnoringBatteryOptimizations,
    required this.canScheduleExactAlarms,
    required this.manufacturer,
    required this.sdkInt,
  });

  const CourseBackgroundKeepAliveStatus.unsupported()
      : supported = false,
        isIgnoringBatteryOptimizations = true,
        canScheduleExactAlarms = true,
        manufacturer = '',
        sdkInt = 0;

  bool get isReady =>
      !supported || (isIgnoringBatteryOptimizations && canScheduleExactAlarms);

  factory CourseBackgroundKeepAliveStatus.fromMap(Map<dynamic, dynamic> map) {
    return CourseBackgroundKeepAliveStatus(
      supported: map['supported'] == true,
      isIgnoringBatteryOptimizations:
          map['isIgnoringBatteryOptimizations'] == true,
      canScheduleExactAlarms: map['canScheduleExactAlarms'] != false,
      manufacturer: map['manufacturer']?.toString() ?? '',
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
    );
  }
}

class CourseReminderService {
  CourseReminderService._();

  static final CourseReminderService instance = CourseReminderService._();

  static const String _enabledKey = 'course_reminder_enabled';
  static const String _notificationIdsKey = 'course_reminder_notification_ids';
  static const String _channelId = 'course_reminders_silent';
  static const String _channelName = '课程提醒';
  static const int _maxPendingNotifications = 60;
  static const MethodChannel _platform =
      MethodChannel('shenliyuan/course_reminders');
  static const List<String> _starts = [
    '08:00',
    '08:55',
    '10:00',
    '10:55',
    '13:00',
    '13:55',
    '14:50',
    '15:45',
    '19:00',
    '19:55',
    '20:50',
    '21:45',
  ];

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
    } catch (_) {}

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
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: '上课前 5 分钟静音提醒',
            importance: Importance.defaultImportance,
            playSound: false,
            enableVibration: false,
          ),
        );

    _initialized = true;
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  Future<int> pendingCourseReminderCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_notificationIdsKey)?.length ?? 0;
  }

  Future<CourseReminderResult> setEnabled(
    bool enabled, {
    required List<CourseBlock> courses,
    required DateTime? semesterStart,
  }) async {
    await initialize();
    final prefs = await SharedPreferences.getInstance();

    if (!enabled) {
      await prefs.setBool(_enabledKey, false);
      await cancelCourseReminders();
      return const CourseReminderResult(
        enabled: false,
        permissionGranted: true,
        scheduledCount: 0,
        message: '课程提醒已关闭',
      );
    }

    final permissionGranted = await requestPermissions();
    if (!permissionGranted) {
      await prefs.setBool(_enabledKey, false);
      return const CourseReminderResult(
        enabled: false,
        permissionGranted: false,
        scheduledCount: 0,
        message: '未获得通知权限',
      );
    }

    await prefs.setBool(_enabledKey, true);
    return reschedule(courses: courses, semesterStart: semesterStart);
  }

  Future<CourseReminderResult> reschedule({
    required List<CourseBlock> courses,
    required DateTime? semesterStart,
  }) async {
    await initialize();
    if (!await isEnabled()) {
      return const CourseReminderResult(
        enabled: false,
        permissionGranted: true,
        scheduledCount: 0,
        message: '课程提醒未开启',
      );
    }

    if (semesterStart == null) {
      await cancelCourseReminders();
      return const CourseReminderResult(
        enabled: true,
        permissionGranted: true,
        scheduledCount: 0,
        message: '请先设置学期开始日期',
      );
    }

    if (courses.isEmpty) {
      await cancelCourseReminders();
      return const CourseReminderResult(
        enabled: true,
        permissionGranted: true,
        scheduledCount: 0,
        message: '暂无课程可提醒',
      );
    }

    await cancelCourseReminders();

    final now = DateTime.now();
    final reminders = _buildReminderEntries(courses, semesterStart, now);
    final pendingReminders =
        reminders.take(_maxPendingNotifications).toList(growable: false);
    final ids = <String>[];

    for (final reminder in pendingReminders) {
      final scheduled = await _scheduleReminder(
        reminder,
        AndroidScheduleMode.exactAllowWhileIdle,
      );
      if (scheduled ||
          await _scheduleReminder(
            reminder,
            AndroidScheduleMode.inexactAllowWhileIdle,
          )) {
        ids.add(reminder.id.toString());
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_notificationIdsKey, ids);

    return CourseReminderResult(
      enabled: true,
      permissionGranted: true,
      scheduledCount: ids.length,
      message: ids.isEmpty ? '没有未来课程可提醒' : '已安排 ${ids.length} 个课程提醒',
    );
  }

  Future<bool> requestPermissions() async {
    await initialize();

    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final androidGranted =
        await androidPlugin?.requestNotificationsPermission() ?? true;
    try {
      await androidPlugin?.requestExactAlarmsPermission();
    } catch (e) {
      debugPrint('精确闹钟权限请求失败: $e');
    }

    final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final iosGranted = await iosPlugin?.requestPermissions(
          alert: true,
          badge: true,
          sound: false,
        ) ??
        true;

    return androidGranted && iosGranted;
  }

  Future<CourseBackgroundKeepAliveStatus> backgroundKeepAliveStatus() async {
    if (!_usesAndroidLiveReminders) {
      return const CourseBackgroundKeepAliveStatus.unsupported();
    }
    try {
      final result = await _platform.invokeMapMethod<String, dynamic>(
        'getAndroidBackgroundStatus',
      );
      if (result == null) {
        return const CourseBackgroundKeepAliveStatus.unsupported();
      }
      return CourseBackgroundKeepAliveStatus.fromMap(result);
    } catch (e) {
      debugPrint('读取 Android 后台保活状态失败: $e');
      return const CourseBackgroundKeepAliveStatus.unsupported();
    }
  }

  Future<CourseBackgroundKeepAliveStatus>
      requestBackgroundKeepAlivePermissions() async {
    if (!_usesAndroidLiveReminders) {
      return const CourseBackgroundKeepAliveStatus.unsupported();
    }

    final status = await backgroundKeepAliveStatus();
    try {
      if (!status.isIgnoringBatteryOptimizations) {
        await _platform.invokeMethod<bool>(
          'requestAndroidBatteryOptimizationExemption',
        );
      } else if (!status.canScheduleExactAlarms) {
        await _platform.invokeMethod<bool>('openAndroidExactAlarmSettings');
      } else {
        await _platform.invokeMethod<bool>(
          'openAndroidBackgroundKeepAliveSettings',
        );
      }
    } catch (e) {
      debugPrint('打开 Android 后台保活设置失败: $e');
    }

    return backgroundKeepAliveStatus();
  }

  Future<bool> _scheduleReminder(
    _CourseReminderEntry reminder,
    AndroidScheduleMode androidScheduleMode,
  ) async {
    try {
      await _plugin.zonedSchedule(
        reminder.id,
        reminder.title,
        reminder.body,
        tz.TZDateTime.from(reminder.time, tz.local),
        _notificationDetails(reminder),
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: androidScheduleMode,
        payload: reminder.payload,
      );
      return true;
    } catch (e) {
      debugPrint('课程提醒排程失败[$androidScheduleMode]: $e');
      return false;
    }
  }

  Future<void> cancelCourseReminders() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_notificationIdsKey) ?? const <String>[];
    final notificationIds = <int>[];
    for (final id in ids) {
      final notificationId = int.tryParse(id);
      if (notificationId != null) {
        notificationIds.add(notificationId);
        await _plugin.cancel(notificationId);
      }
    }
    await _cancelAndroidLiveReminders(notificationIds);
    await prefs.remove(_notificationIdsKey);
  }

  bool get _usesAndroidLiveReminders =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _cancelAndroidLiveReminders(List<int> ids) async {
    if (!_usesAndroidLiveReminders) return;
    try {
      await _platform.invokeMethod<void>(
        'cancelAndroidLiveReminders',
        {'ids': ids},
      );
    } catch (e) {
      debugPrint('Android Live Updates 课程提醒取消失败: $e');
    }
  }

  NotificationDetails _notificationDetails(_CourseReminderEntry reminder) {
    final teacher = reminder.course.teacher?.trim();
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: '上课前 5 分钟静音提醒',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        styleInformation: BigTextStyleInformation(
          reminder.detailText,
          contentTitle: reminder.title,
          summaryText: '静音提醒 · 即将上课',
        ),
        playSound: false,
        enableVibration: false,
        silent: true,
        autoCancel: false,
        ongoing: true,
        onlyAlertOnce: true,
        timeoutAfter: const Duration(minutes: 6).inMilliseconds,
        ticker: _tickerFor(reminder.course),
        category: AndroidNotificationCategory.reminder,
        visibility: NotificationVisibility.public,
        color: const Color(0xFF4F46E5),
        colorized: false,
        subText: '课前静音提醒',
        when: reminder.classStart.millisecondsSinceEpoch,
        usesChronometer: true,
        chronometerCountDown: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBanner: true,
        presentList: true,
        presentSound: false,
        subtitle: teacher == null || teacher.isEmpty ? null : teacher,
        interruptionLevel: InterruptionLevel.active,
        threadIdentifier: 'course_reminders',
      ),
    );
  }

  List<_CourseReminderEntry> _buildReminderEntries(
    List<CourseBlock> courses,
    DateTime semesterStart,
    DateTime now,
  ) {
    final start = DateTime(
      semesterStart.year,
      semesterStart.month,
      semesterStart.day,
    ).subtract(Duration(days: semesterStart.weekday - 1));
    final entries = <_CourseReminderEntry>[];

    for (final course in courses) {
      final weeks =
          course.weeks.isEmpty ? _fallbackWeeks(start, now) : course.weeks;
      for (final week in weeks) {
        if (course.startSection < 1 || course.startSection > _starts.length) {
          continue;
        }
        final timeParts = _starts[course.startSection - 1].split(':');
        final classDate = start.add(Duration(
          days: (week - 1) * 7 + (course.weekday - 1),
        ));
        final classStart = DateTime(
          classDate.year,
          classDate.month,
          classDate.day,
          int.parse(timeParts[0]),
          int.parse(timeParts[1]),
        );
        final reminderAt = classStart.subtract(const Duration(minutes: 5));
        if (!reminderAt.isAfter(now)) continue;

        entries.add(_CourseReminderEntry(
          id: _notificationId(course, reminderAt),
          course: course,
          time: reminderAt,
          classStart: classStart,
          title: _titleFor(course),
          body: _bodyFor(course),
          detailText: _detailTextFor(course, classStart),
          payload: 'course:${course.id}:${reminderAt.toIso8601String()}',
        ));
      }
    }

    entries.sort((a, b) => a.time.compareTo(b.time));
    return entries;
  }

  List<int> _fallbackWeeks(DateTime semesterStart, DateTime now) {
    final currentWeek =
        max(1, (now.difference(semesterStart).inDays / 7).floor() + 1);
    return List.generate(8, (index) => currentWeek + index);
  }

  int _notificationId(CourseBlock course, DateTime time) {
    final raw = '${course.courseCode}|${course.name}|${course.weekday}|'
        '${course.startSection}|${time.toIso8601String()}';
    var hash = 0;
    for (final codeUnit in raw.codeUnits) {
      hash = (hash * 31 + codeUnit) & 0x7fffffff;
    }
    return hash;
  }

  String _titleFor(CourseBlock course) {
    final name = course.name.isEmpty ? '课程' : course.name;
    return '即将上课 · $name';
  }

  String _tickerFor(CourseBlock course) {
    final name = course.name.isEmpty ? '课程' : course.name;
    final teacher = course.teacher?.trim();
    if (teacher != null && teacher.isNotEmpty) {
      return '$teacher · $name · 即将开始';
    }
    return '$name · 即将开始';
  }

  String _bodyFor(CourseBlock course) {
    final parts = <String>[];
    final teacher = course.teacher?.trim();
    final location = course.location?.trim();
    if (teacher != null && teacher.isNotEmpty) parts.add(teacher);
    if (location != null && location.isNotEmpty) parts.add(location);
    parts.add('第${course.startSection}-${course.endSection}节');
    return parts.join(' · ');
  }

  String _detailTextFor(CourseBlock course, DateTime classStart) {
    final lines = <String>[];
    final teacher = course.teacher?.trim();
    final location = course.location?.trim();
    if (teacher != null && teacher.isNotEmpty) lines.add('教师：$teacher');
    if (location != null && location.isNotEmpty) lines.add('教室：$location');
    lines.add('节次：第${course.startSection}-${course.endSection}节');
    lines.add('开始时间：${_hm(classStart)}');
    return lines.join('\n');
  }

  String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _CourseReminderEntry {
  final int id;
  final CourseBlock course;
  final DateTime time;
  final DateTime classStart;
  final String title;
  final String body;
  final String detailText;
  final String payload;

  const _CourseReminderEntry({
    required this.id,
    required this.course,
    required this.time,
    required this.classStart,
    required this.title,
    required this.body,
    required this.detailText,
    required this.payload,
  });
}
