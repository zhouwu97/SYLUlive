import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/app_platform.dart';
import 'package:shenliyuan/platform/notification/notification_service.dart';
import 'package:shenliyuan/platform/platform_capabilities.dart';
import 'package:shenliyuan/platform/platform_services.dart';

void main() {
  test('平台能力只暴露已经接入的鸿蒙功能', () {
    final capabilities = PlatformCapabilities.forPlatform(AppPlatform.ohos);

    expect(capabilities.supportsJPush, isFalse);
    expect(capabilities.supportsNativeWidget, isFalse);
    expect(capabilities.supportsLiveView, isFalse);
    expect(capabilities.supportsScanKit, isFalse);
    expect(capabilities.supportsInAppPackageInstall, isFalse);
    expect(capabilities.supportsFileImportExport, isFalse);
    expect(capabilities.supportsSystemCalendar, isFalse);
  });

  test('Android 保留原有系统能力', () {
    final capabilities = PlatformCapabilities.forPlatform(AppPlatform.android);

    expect(capabilities.supportsJPush, isTrue);
    expect(capabilities.supportsNativeWidget, isTrue);
    expect(capabilities.supportsBackgroundReminder, isTrue);
    expect(capabilities.supportsInAppPackageInstall, isTrue);
    expect(capabilities.supportsFileImportExport, isTrue);
    expect(capabilities.supportsSystemCalendar, isTrue);
  });

  test('iOS 保留文件与系统日历能力，Web 和其他平台默认关闭', () {
    final ios = PlatformCapabilities.forPlatform(AppPlatform.ios);
    final web = PlatformCapabilities.forPlatform(AppPlatform.web);
    final other = PlatformCapabilities.forPlatform(AppPlatform.other);

    expect(ios.supportsFileImportExport, isTrue);
    expect(ios.supportsSystemCalendar, isTrue);
    expect(web.supportsFileImportExport, isFalse);
    expect(web.supportsSystemCalendar, isFalse);
    expect(other.supportsFileImportExport, isFalse);
    expect(other.supportsSystemCalendar, isFalse);
  });

  test('OHOS 通知入口保持未接入状态', () {
    final notifications =
        PlatformServices.forPlatform(AppPlatform.ohos).notifications;

    expect(notifications, isA<NoopNotificationService>());
    expect(notifications.isSupported, isFalse);
    expect(notifications.isReadyForPrivateMessages, isFalse);
  });

  test('平台服务按平台复用实例，保证有状态能力不会重复初始化', () {
    final first = PlatformServices.forPlatform(AppPlatform.ohos);
    final second = PlatformServices.forPlatform(AppPlatform.ohos);

    expect(identical(first, second), isTrue);
    expect(identical(first.liveView, second.liveView), isTrue);
  });

  test('应用入口和平台聚合层不引用 Android 通知实现', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final servicesSource =
        File('lib/platform/platform_services.dart').readAsStringSync();
    final coordinatorSource = File(
      'lib/platform/notification/app_notification_service.dart',
    ).readAsStringSync();

    expect(mainSource, isNot(contains('AndroidNotificationService')));
    expect(mainSource, isNot(contains('android_notification_service.dart')));
    expect(mainSource, isNot(contains('JPush')));
    expect(servicesSource, isNot(contains('AndroidNotificationService')));
    expect(
        servicesSource, isNot(contains('android_notification_service.dart')));
    expect(
      coordinatorSource,
      isNot(contains('AndroidFlutterLocalNotificationsPlugin')),
    );
    expect(coordinatorSource, isNot(contains('flutter_local_notifications')));
    expect(coordinatorSource, isNot(contains('MethodChannel')));
  });
}
