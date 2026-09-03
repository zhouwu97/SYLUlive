import '../other/unsupported_reminder_notification_client.dart';

abstract class ReminderNotificationClient {
  static ReminderNotificationClient? _instance;

  static void register(ReminderNotificationClient instance) {
    _instance = instance;
  }

  static ReminderNotificationClient get instance {
    if (_instance != null) return _instance!;
    _instance = UnsupportedReminderNotificationClient();
    return _instance!;
  }

  Future<void> initializeCourseReminders();
  Future<bool> requestCourseReminderPermissions();
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
  });
  Future<void> cancelCourseReminder(int id);

  /// 显示一次即时的本地成绩更新通知；不触发任何网络请求。
  Future<bool> showGradeUpdate({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async =>
      false;

  /// 通用个人日历提醒。平台不支持时保留服务端提醒，不影响日历数据。
  Future<bool> scheduleCalendarReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    required String payload,
  }) async =>
      false;

  Future<void> cancelCalendarReminder(int id) async {}
}
