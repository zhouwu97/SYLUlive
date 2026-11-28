import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shenliyuan/platform/ohos/ohos_reminder_notification_client.dart';
import 'package:shenliyuan/platform/app_platform.dart';
import 'package:shenliyuan/platform/platform_capabilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('鸿蒙日程使用同一分类取消，过去时间不会触发原生调度', () async {
    const channel = MethodChannel('shenliyuan/ohos_reminders');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'schedule' ? true : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final client = OhosReminderNotificationClient();
    Future<bool> schedule(DateTime time) => client.scheduleCalendarReminder(
      id: 11, title: '考试', body: '教室', scheduledTime: time, payload: 'calendar');
    expect(await schedule(DateTime(2000)), isFalse);
    expect(calls, isEmpty);
    expect(await schedule(DateTime.now().add(const Duration(minutes: 3))), isTrue);
    await client.cancelCalendarReminder(11);
    expect(calls.first.arguments['group'], 'calendar');
    expect(calls.last.arguments, {'group': 'calendar', 'id': 11});
  });
  test('平台能力只暴露已经接入的鸿蒙功能', () {
    final capabilities = PlatformCapabilities.forPlatform(AppPlatform.ohos);

    expect(capabilities.supportsJPush, isTrue);
    expect(capabilities.supportsSystemNotification, isTrue);
    expect(capabilities.supportsNativeWidget, isTrue);
    expect(capabilities.supportsBackgroundReminder, isTrue);
    expect(capabilities.supportsLiveView, isFalse);
    expect(capabilities.supportsScanKit, isFalse);
    expect(capabilities.supportsInAppPackageInstall, isFalse);
  });

  test('Android 保留原有系统能力', () {
    final capabilities = PlatformCapabilities.forPlatform(AppPlatform.android);

    expect(capabilities.supportsJPush, isTrue);
    expect(capabilities.supportsNativeWidget, isTrue);
    expect(capabilities.supportsBackgroundReminder, isTrue);
    expect(capabilities.supportsInAppPackageInstall, isTrue);
  });

  test('iOS 是独立的一等平台并启用 Apple 对应能力', () {
    final capabilities = PlatformCapabilities.forPlatform(AppPlatform.ios);

    expect(AppPlatform.ios.wireName, 'ios');
    expect(AppPlatform.ios.isIOS, isTrue);
    expect(capabilities.supportsJPush, isTrue);
    expect(capabilities.supportsSystemNotification, isTrue);
    expect(capabilities.supportsSensitiveSecretStorage, isTrue);
    expect(capabilities.supportsNativeWidget, isTrue);
    expect(capabilities.supportsPdfPreview, isTrue);
    expect(capabilities.supportsInAppPackageInstall, isFalse);
    expect(capabilities.supportsLiveView, isFalse);
  });

  test('macOS 暴露课程提醒能力但不启用 Android 专属能力', () {
    final capabilities = PlatformCapabilities.forPlatform(AppPlatform.macos);

    expect(AppPlatform.macos.wireName, 'macos');
    expect(AppPlatform.macos.isMacOS, isTrue);
    expect(capabilities.supportsBackgroundReminder, isTrue);
    expect(capabilities.supportsSystemNotification, isFalse);
    expect(capabilities.supportsJPush, isFalse);
    expect(capabilities.supportsInAppPackageInstall, isFalse);
  });
}
