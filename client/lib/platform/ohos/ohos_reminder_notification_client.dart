import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../contracts/reminder_notification_client.dart';

class OhosReminderNotificationClient implements ReminderNotificationClient {
  static const _channel = MethodChannel('shenliyuan/ohos_reminders');

  @override
  Future<void> initializeCourseReminders() async {}

  @override
  Future<bool> requestCourseReminderPermissions() async {
    return await _channel.invokeMethod<bool>('requestPermission') ?? false;
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
    return _schedule('course', id, title, body, scheduledTime);
  }

  @override
  Future<void> cancelCourseReminder(int id) async {
    await _cancel('course', id);
  }

  @override
  Future<bool> scheduleCalendarReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    required String payload,
  }) async {
    return _schedule('calendar', id, title, body, scheduledTime);
  }

  @override
  Future<void> cancelCalendarReminder(int id) async {
    await _cancel('calendar', id);
  }

  Future<bool> _schedule(
      String group, int id, String title, String body, DateTime time) async {
    if (!time.isAfter(DateTime.now())) return false;
    try {
      return await _channel.invokeMethod<bool>('schedule', {
            'group': group,
            'id': id,
            'title': title,
            'body': body,
            'time': time.millisecondsSinceEpoch,
          }) ?? false;
    } on PlatformException catch (e) {
      if (e.code != 'OHOS_REMINDER_SCHEDULE') rethrow;
      debugPrint('鸿蒙系统未接受提醒，错误码 ${e.details}');
      return false;
    }
  }

  Future<void> _cancel(String group, int id) =>
      _channel.invokeMethod<void>('cancel', {'group': group, 'id': id});
}
