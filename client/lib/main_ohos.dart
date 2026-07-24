import 'app_bootstrap.dart';
import 'platform/contracts/reminder_notification_client.dart';
import 'platform/ohos/ohos_reminder_notification_client.dart';

void main() {
  ReminderNotificationClient.register(OhosReminderNotificationClient());
  appBootstrap();
}
