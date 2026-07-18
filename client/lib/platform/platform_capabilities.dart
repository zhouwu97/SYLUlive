import 'app_platform.dart';

/// 平台能力开关。
///
/// 这里表达的是“已经接入且可向用户暴露”的能力，而不是系统理论上可能支持的
/// 能力。鸿蒙原生桥接完成并经过真机验收前必须保持关闭，避免出现无效入口。
class PlatformCapabilities {
  const PlatformCapabilities._({
    required this.platform,
    required this.supportsJPush,
    required this.supportsNativeWidget,
    required this.supportsLiveView,
    required this.supportsScanKit,
    required this.supportsPdfPreview,
    required this.supportsBackgroundReminder,
    required this.supportsInAppPackageInstall,
    required this.supportsFileImportExport,
    required this.supportsSystemCalendar,
  });

  final AppPlatform platform;
  final bool supportsJPush;
  final bool supportsNativeWidget;
  final bool supportsLiveView;
  final bool supportsScanKit;
  final bool supportsPdfPreview;
  final bool supportsBackgroundReminder;
  final bool supportsInAppPackageInstall;
  final bool supportsFileImportExport;
  final bool supportsSystemCalendar;

  static PlatformCapabilities get current => forPlatform(AppPlatforms.current);

  static PlatformCapabilities forPlatform(AppPlatform platform) =>
      switch (platform) {
        AppPlatform.android => const PlatformCapabilities._(
            platform: AppPlatform.android,
            supportsJPush: true,
            supportsNativeWidget: true,
            supportsLiveView: false,
            supportsScanKit: false,
            supportsPdfPreview: true,
            supportsBackgroundReminder: true,
            supportsInAppPackageInstall: true,
            supportsFileImportExport: true,
            supportsSystemCalendar: true,
          ),
        AppPlatform.ohos => const PlatformCapabilities._(
            platform: AppPlatform.ohos,
            supportsJPush: false,
            supportsNativeWidget: false,
            supportsLiveView: false,
            supportsScanKit: false,
            supportsPdfPreview: false,
            supportsBackgroundReminder: false,
            supportsInAppPackageInstall: false,
            supportsFileImportExport: false,
            supportsSystemCalendar: false,
          ),
        AppPlatform.ios => const PlatformCapabilities._(
            platform: AppPlatform.ios,
            supportsJPush: false,
            supportsNativeWidget: false,
            supportsLiveView: false,
            supportsScanKit: false,
            supportsPdfPreview: true,
            supportsBackgroundReminder: false,
            supportsInAppPackageInstall: false,
            supportsFileImportExport: true,
            supportsSystemCalendar: true,
          ),
        AppPlatform.web || AppPlatform.other => PlatformCapabilities._(
            platform: platform,
            supportsJPush: false,
            supportsNativeWidget: false,
            supportsLiveView: false,
            supportsScanKit: false,
            supportsPdfPreview: false,
            supportsBackgroundReminder: false,
            supportsInAppPackageInstall: false,
            supportsFileImportExport: false,
            supportsSystemCalendar: false,
          ),
      };
}
