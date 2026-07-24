import 'app_bootstrap.dart';
import 'platform/contracts/reminder_notification_client.dart';
import 'platform/contracts/push_client.dart';
import 'platform/contracts/system_notification_client.dart';
import 'platform/contracts/external_navigator.dart';
import 'platform/ohos/ohos_reminder_notification_client.dart';
import 'platform/ohos/ohos_external_navigator.dart';

void main() {
  ReminderNotificationClient.register(OhosReminderNotificationClient());
  PushClient.register(UnsupportedPushClient());
  SystemNotificationClient.register(UnsupportedSystemNotificationClient());
  ExternalNavigator.register(const OhosExternalNavigator());
  appBootstrap();
}
