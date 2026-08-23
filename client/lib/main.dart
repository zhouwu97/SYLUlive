import 'app_bootstrap.dart';
import 'platform/contracts/reminder_notification_client.dart';
import 'platform/contracts/push_client.dart';
import 'platform/contracts/system_notification_client.dart';
import 'platform/contracts/external_navigator.dart';
import 'platform/android/android_reminder_notification_client.dart';
import 'platform/android/android_push_client.dart';
import 'platform/android/android_system_notification_client.dart';
import 'platform/android/android_external_navigator.dart';
import 'platform/app_platform.dart';
import 'platform/darwin/darwin_reminder_notification_client.dart';

void main() {
  if (AppPlatforms.current.isMacOS) {
    ReminderNotificationClient.register(DarwinReminderNotificationClient());
    PushClient.register(UnsupportedPushClient());
    SystemNotificationClient.register(UnsupportedSystemNotificationClient());
    ExternalNavigator.register(const UnsupportedExternalNavigator());
  } else {
    ReminderNotificationClient.register(AndroidReminderNotificationClient());
    PushClient.register(AndroidJPushClient());
    SystemNotificationClient.register(AndroidSystemNotificationClient());
    ExternalNavigator.register(const AndroidExternalNavigator());
  }
  appBootstrap();
}
