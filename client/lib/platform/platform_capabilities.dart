import 'app_platform.dart';

/// 平台能力开关。
///
/// 这里表达的是“已经接入且可向用户暴露”的能力，而不是系统理论上可能支持的
/// 能力。鸿蒙原生桥接完成并经过真机验收前必须保持关闭，避免出现无效入口。
class PlatformCapabilities {
  const PlatformCapabilities._({
    required this.platform,
    required this.supportsJPush,
    required this.supportsSystemNotification,
    required this.supportsPersistentStorage,
    required this.supportsSensitiveSecretStorage,
    required this.supportsMarketUpdate,
    required this.supportsNativeWidget,
    required this.supportsLiveView,
    required this.supportsScanKit,
    required this.supportsPdfPreview,
    required this.supportsBackgroundReminder,
    required this.supportsInAppPackageInstall,
  });

  final AppPlatform platform;
  final bool supportsJPush;
  final bool supportsSystemNotification;
  final bool supportsPersistentStorage;
  final bool supportsSensitiveSecretStorage;
  final bool supportsMarketUpdate;
  final bool supportsNativeWidget;
  final bool supportsLiveView;
  final bool supportsScanKit;
  final bool supportsPdfPreview;
  final bool supportsBackgroundReminder;
  final bool supportsInAppPackageInstall;

  static PlatformCapabilities get current => forPlatform(AppPlatforms.current);

  static PlatformCapabilities forPlatform(AppPlatform platform) =>
      switch (platform) {
        AppPlatform.android => const PlatformCapabilities._(
            platform: AppPlatform.android,
            supportsJPush: true,
            supportsSystemNotification: true,
            supportsPersistentStorage: true,
            supportsSensitiveSecretStorage: true,
            supportsMarketUpdate: false,
            supportsNativeWidget: true,
            supportsLiveView: false,
            supportsScanKit: false,
            supportsPdfPreview: true,
            supportsBackgroundReminder: true,
            supportsInAppPackageInstall: true,
          ),
        AppPlatform.ios => const PlatformCapabilities._(
            platform: AppPlatform.ios,
            supportsJPush: true,
            supportsSystemNotification: true,
            supportsPersistentStorage: true,
            supportsSensitiveSecretStorage: true,
            supportsMarketUpdate: true,
            supportsNativeWidget: true,
            supportsLiveView: false,
            supportsScanKit: false,
            supportsPdfPreview: true,
            supportsBackgroundReminder: true,
            supportsInAppPackageInstall: false,
          ),
        AppPlatform.ohos => const PlatformCapabilities._(
            platform: AppPlatform.ohos,
            supportsJPush: false,
            supportsSystemNotification: false,
            supportsPersistentStorage: true,
            supportsSensitiveSecretStorage: true,
            supportsMarketUpdate: false,
            supportsNativeWidget: false,
            supportsLiveView: false,
            supportsScanKit: false,
            supportsPdfPreview: false,
            supportsBackgroundReminder: false,
            supportsInAppPackageInstall: false,
          ),
        AppPlatform.macos => const PlatformCapabilities._(
            platform: AppPlatform.macos,
            supportsJPush: false,
            supportsSystemNotification: false,
            supportsPersistentStorage: true,
            supportsSensitiveSecretStorage: false,
            supportsMarketUpdate: false,
            supportsNativeWidget: false,
            supportsLiveView: false,
            supportsScanKit: false,
            supportsPdfPreview: false,
            supportsBackgroundReminder: true,
            supportsInAppPackageInstall: false,
          ),
        AppPlatform.web || AppPlatform.other => PlatformCapabilities._(
            platform: platform,
            supportsJPush: false,
            supportsSystemNotification: false,
            supportsPersistentStorage: true,
            supportsSensitiveSecretStorage: false,
            supportsMarketUpdate: false,
            supportsNativeWidget: false,
            supportsLiveView: false,
            supportsScanKit: false,
            supportsPdfPreview: false,
            supportsBackgroundReminder: false,
            supportsInAppPackageInstall: false,
          ),
      };
}
