import 'dart:async';

import '../app_platform.dart';

/// 应用更新查询/安装能力的服务接口。
///
/// 计划 11.2：当前 Android 通过 `services/app_update_coordinator.dart`
/// 走 `shenliyuan/app_update` MethodChannel 落地 APK 自更新；
/// 鸿蒙计划 16 中明确：错误下载 APK 替代 HAP、应用市场优先、无 HAP 发布记录时
/// 必须返回 200 + `update_available=false`。本接口供下游对接统一调用面。
abstract class AppUpdateService {
  AppPlatform get platform;
  bool get isSupported;

  /// 拉取可用更新信息。无可用更新时返回可用性为 [UpdateAvailability.noUpdate]。
  Future<UpdateCheckResult> checkForUpdates();

  /// 触发安装（鸿蒙：引导到应用市场或官方 HAP 分发页；不允许偷偷下载 APK）。
  /// `promptUser` 为是否先弹出确认；为 false 时实现可自行决定是否直接落盘。
  Future<void> promptInstall({
    required String artifactUrl,
    required int versionCode,
    bool promptUser = true,
  });

  Future<void> dispose();
}

enum UpdateAvailability { noUpdate, optional, required }

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.availability,
    this.versionName,
    this.versionCode,
    this.artifactUrl,
    this.releaseNotes,
  });

  final UpdateAvailability availability;
  final String? versionName;
  final int? versionCode;
  final String? artifactUrl;
  final String? releaseNotes;
}

class NoopAppUpdateService implements AppUpdateService {
  const NoopAppUpdateService({required this.platform});

  @override
  final AppPlatform platform;

  @override
  bool get isSupported => false;

  @override
  Future<UpdateCheckResult> checkForUpdates() async =>
      const UpdateCheckResult(availability: UpdateAvailability.noUpdate);

  @override
  Future<void> promptInstall({
    required String artifactUrl,
    required int versionCode,
    bool promptUser = true,
  }) async {}

  @override
  Future<void> dispose() async {}
}