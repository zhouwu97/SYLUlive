import 'app_bootstrap.dart';
import 'platform/contracts/reminder_notification_client.dart';
import 'platform/android/android_reminder_notification_client.dart';

void main() {
  ReminderNotificationClient.register(AndroidReminderNotificationClient());
  appBootstrap();
}
