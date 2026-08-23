import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/platform/app_platform.dart';
import 'package:shenliyuan/platform/platform_capabilities.dart';

void main() {
  test('平台能力只暴露已经接入的鸿蒙功能', () {
    final capabilities = PlatformCapabilities.forPlatform(AppPlatform.ohos);

    expect(capabilities.supportsJPush, isFalse);
    expect(capabilities.supportsNativeWidget, isFalse);
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
