import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart' as crypto;

import '../../models/app_update_info.dart';
import '../app_platform.dart';
import '../platform_capabilities.dart';
import '../app_installer.dart';
import 'external_navigator.dart';
import '../../services/app_update_download_service.dart';
import 'dart:io';

enum AppUpdateActionResult {
  installerOpened,
  permissionRequired,
  externalStoreOpened,
}

/// 已准备好的更新包及其服务端发布元数据。
///
/// 只有元数据和文件内容都仍匹配当前发布信息时，才允许跨一次更新操作复用。
class PreparedUpdatePackage {
  const PreparedUpdatePackage({
    required this.file,
    required this.versionCode,
    required this.sha256,
    required this.fileSize,
  });

  final File file;
  final int versionCode;
  final String sha256;
  final int fileSize;

  /// 校验包是否仍属于当前发布，避免新版本安装流程复用旧 APK。
  Future<bool> isValidFor(AppUpdateInfo info) async {
    if (versionCode != info.latestVersionCode ||
        fileSize != info.fileSize ||
        sha256.toLowerCase() != info.sha256.toLowerCase()) {
      return false;
    }
    try {
      if (!await file.exists() || await file.length() != fileSize) return false;
      final actualSha = await crypto.sha256.bind(file.openRead()).first;
      return actualSha.toString().toLowerCase() == info.sha256.toLowerCase();
    } catch (_) {
      return false;
    }
  }

  Future<void> deleteIfExists() async {
    if (await file.exists()) await file.delete();
  }
}

abstract interface class AppUpdateAction {
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    PreparedUpdatePackage? existingPackage,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  });

  PreparedUpdatePackage? get readyPackage;

  factory AppUpdateAction.current(AppUpdateInfo info, AppInstaller installer,
      AppUpdateDownloadService downloadService) {
    final capabilities = PlatformCapabilities.current;

    // 如果是鸿蒙平台，只有在服务端明确指明为 external_market 且提供了有效 actionUrl 时才允许外部跳转
    if (capabilities.platform == AppPlatform.ohos) {
      if (info.deliveryMode == AppUpdateDeliveryMode.externalMarket &&
          info.actionUrl.trim().isNotEmpty) {
        return const OhosMarketUpdateAction();
      }
      return const UnsupportedUpdateAction();
    }

    if (capabilities.platform == AppPlatform.ios) {
      return const IOSAppStoreUpdateAction();
    }

    if (capabilities.supportsMarketUpdate) {
      return const OhosMarketUpdateAction();
    }
    if (capabilities.supportsInAppPackageInstall) {
      return AndroidApkUpdateAction(installer, downloadService);
    }
    return const UnsupportedUpdateAction();
  }
}

class UnsupportedUpdateAction implements AppUpdateAction {
  const UnsupportedUpdateAction();

  @override
  PreparedUpdatePackage? get readyPackage => null;

  @override
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    PreparedUpdatePackage? existingPackage,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    throw StateError('当前平台不支持应用内更新');
  }
}

class OhosMarketUpdateAction implements AppUpdateAction {
  const OhosMarketUpdateAction();

  @override
  PreparedUpdatePackage? get readyPackage => null;

  @override
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    PreparedUpdatePackage? existingPackage,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final canOpenExternal =
        info.deliveryMode == AppUpdateDeliveryMode.externalMarket &&
            info.actionUrl.trim().isNotEmpty;
    final targetUrl =
        canOpenExternal ? info.actionUrl.trim() : info.downloadUrl.trim();
    if (targetUrl.isEmpty) throw StateError('更新链接无效');
    final url = Uri.tryParse(targetUrl);
    if (url == null) throw StateError('更新链接无效');

    final nav = ExternalNavigator.current();
    final opened = await nav.open(url);
    if (!opened) {
      throw StateError('无法打开应用市场或链接，请手动更新');
    }
    return AppUpdateActionResult.externalStoreOpened;
  }
}

/// iOS 通过 App Store / TestFlight 分发，禁止下载 IPA 后由 App 内安装。
class IOSAppStoreUpdateAction implements AppUpdateAction {
  const IOSAppStoreUpdateAction();

  @override
  PreparedUpdatePackage? get readyPackage => null;

  @override
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    PreparedUpdatePackage? existingPackage,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final target = info.actionUrl.trim().isNotEmpty
        ? info.actionUrl.trim()
        : info.downloadUrl.trim();
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw StateError('App Store 更新链接无效');
    }
    final opened = await ExternalNavigator.current().open(uri);
    if (!opened) throw StateError('无法打开 App Store 或 TestFlight');
    return AppUpdateActionResult.externalStoreOpened;
  }
}

class AndroidApkUpdateAction implements AppUpdateAction {
  final AppInstaller _installer;
  final AppUpdateDownloadService _downloadService;

  AndroidApkUpdateAction(this._installer, this._downloadService);

  PreparedUpdatePackage? _preparedPackage;

  @override
  PreparedUpdatePackage? get readyPackage => _preparedPackage;

  @override
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    PreparedUpdatePackage? existingPackage,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // 1. 仅复用仍与当前发布信息完全匹配的包，避免检查期间版本变化时安装旧 APK。
    var preparedPackage = existingPackage;
    if (preparedPackage == null || !await preparedPackage.isValidFor(info)) {
      if (preparedPackage != null) {
        try {
          await preparedPackage.deleteIfExists();
        } catch (error) {
          // 旧包清理失败不应阻断重新下载；新包校验成功后仍可继续安装。
          debugPrint('清理失效更新包失败: ${error.runtimeType}');
        }
      }
      try {
        final apk = await _downloadService.download(
          url: info.downloadUrl,
          expectedSize: info.fileSize,
          expectedSha256: info.sha256.toLowerCase(),
          cancelToken: cancelToken,
          onProgress: onProgress,
        );
        final downloadedPackage = PreparedUpdatePackage(
          file: apk,
          versionCode: info.latestVersionCode,
          sha256: info.sha256,
          fileSize: info.fileSize,
        );
        if (!await downloadedPackage.isValidFor(info)) {
          throw StateError('更新包校验失败');
        }
        preparedPackage = downloadedPackage;
      } catch (e) {
        if (cancelToken?.isCancelled ?? false) {
          throw StateError('用户暂停下载');
        }
        rethrow;
      }
    }

    _preparedPackage = preparedPackage;

    // 2. Check Permission
    if (!await _installer.canInstallPackages()) {
      await _installer.openInstallPermissionSettings();
      return AppUpdateActionResult.permissionRequired;
    }

    // 3. Install
    try {
      await _installer.installApk(preparedPackage.file);
      _preparedPackage = null;
      return AppUpdateActionResult.installerOpened;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '无法打开系统安装器');
    }
  }
}
