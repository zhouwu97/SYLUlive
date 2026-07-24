import '../app_platform.dart';
import '../android/android_reminder_notification_client.dart';
import '../ohos/ohos_reminder_notification_client.dart';
import '../other/unsupported_reminder_notification_client.dart';

abstract class ReminderNotificationClient {
  static ReminderNotificationClient? _instance;

  static ReminderNotificationClient get instance {
    if (_instance != null) return _instance!;
    _instance = switch (AppPlatforms.current) {
      AppPlatform.android => AndroidReminderNotificationClient(),
      AppPlatform.ohos => OhosReminderNotificationClient(),
      AppPlatform.web || AppPlatform.other => UnsupportedReminderNotificationClient(),
    };
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

  Future<void> initializeGradeReminders();
  Future<bool> requestGradeReminderPermissions();
}
