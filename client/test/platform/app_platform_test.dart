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
}
