import '../contracts/reminder_notification_client.dart';

class OhosReminderNotificationClient implements ReminderNotificationClient {
  @override
  Future<void> initializeCourseReminders() async {
    // Unsupported on OHOS for now
  }

  @override
  Future<bool> requestCourseReminderPermissions() async {
    return false; // Unsupported on OHOS for now
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
    return false; // Unsupported on OHOS for now
  }

  @override
  Future<void> cancelCourseReminder(int id) async {
    // Unsupported on OHOS for now
  }

  @override
  Future<bool> showGradeUpdate({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    // 鸿蒙端当前没有接入统一本地通知实现。
    return false;
  }

  @override
  Future<bool> scheduleCalendarReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    required String payload,
  }) async {
    // Unsupported on OHOS for now; server-side reminder remains available.
    return false;
  }

  @override
  Future<void> cancelCalendarReminder(int id) async {
    // Unsupported on OHOS for now
  }
}
