import 'app_bootstrap.dart';
import 'platform/contracts/reminder_notification_client.dart';
import 'platform/contracts/push_client.dart';
import 'platform/contracts/system_notification_client.dart';
import 'platform/contracts/external_navigator.dart';
import 'platform/app_platform.dart';
import 'platform/common/jpush_client.dart';
import 'platform/common/local_reminder_notification_client.dart';
import 'platform/common/system_notification_client.dart';
import 'platform/common/url_launcher_external_navigator.dart';
import 'platform/darwin/darwin_reminder_notification_client.dart';
import 'platform/other/unsupported_reminder_notification_client.dart';

void _registerPlatformClients() {
  switch (AppPlatforms.current) {
    case AppPlatform.android:
    case AppPlatform.ios:
      ReminderNotificationClient.register(LocalReminderNotificationClient());
      PushClient.register(JPushClient());
      SystemNotificationClient.register(LocalSystemNotificationClient());
      ExternalNavigator.register(const UrlLauncherExternalNavigator());
    case AppPlatform.macos:
      ReminderNotificationClient.register(DarwinReminderNotificationClient());
      PushClient.register(UnsupportedPushClient());
      SystemNotificationClient.register(UnsupportedSystemNotificationClient());
      ExternalNavigator.register(const UnsupportedExternalNavigator());
    case AppPlatform.ohos:
    case AppPlatform.web:
    case AppPlatform.other:
      ReminderNotificationClient.register(
        UnsupportedReminderNotificationClient(),
      );
      PushClient.register(UnsupportedPushClient());
      SystemNotificationClient.register(UnsupportedSystemNotificationClient());
      ExternalNavigator.register(const UnsupportedExternalNavigator());
  }
}

void main() {
  _registerPlatformClients();
  appBootstrap();
}
