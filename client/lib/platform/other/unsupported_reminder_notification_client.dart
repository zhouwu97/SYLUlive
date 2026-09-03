import '../contracts/reminder_notification_client.dart';

class UnsupportedReminderNotificationClient
    implements ReminderNotificationClient {
  @override
  Future<void> initializeCourseReminders() async {}

  @override
  Future<bool> requestCourseReminderPermissions() async => false;

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
  }) async =>
      false;

  @override
  Future<void> cancelCourseReminder(int id) async {}

  @override
  Future<bool> showGradeUpdate({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async =>
      false;

  @override
  Future<bool> scheduleCalendarReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    required String payload,
  }) async =>
      false;

  @override
  Future<void> cancelCalendarReminder(int id) async {}
}
