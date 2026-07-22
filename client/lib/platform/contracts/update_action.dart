import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';

import '../../models/app_update_info.dart';
import '../app_platform.dart';
import '../platform_capabilities.dart';
import '../app_installer.dart';
import 'external_navigator.dart';
import '../../services/app_update_download_service.dart';
import 'dart:io';

enum AppUpdateActionResult {
  success,
  needPermission,
  failed,
}

abstract interface class AppUpdateAction {
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    File? existingApk,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  });

  File? get readyApk;

  factory AppUpdateAction.current(AppInstaller installer, AppUpdateDownloadService downloadService) {
    final capabilities = PlatformCapabilities.current;
    if (capabilities.supportsMarketUpdate) {
      return const OhosMarketUpdateAction();
    }
    if (capabilities.supportsInAppPackageInstall) {
      return AndroidApkUpdateAction(installer, downloadService);
    }
    return UnsupportedUpdateAction();
  }
}

class UnsupportedUpdateAction implements AppUpdateAction {
  const UnsupportedUpdateAction();

  @override
  File? get readyApk => null;

  @override
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    File? existingApk,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    throw StateError('当前平台不支持应用内更新');
  }
}

class OhosMarketUpdateAction implements AppUpdateAction {
  const OhosMarketUpdateAction();

  @override
  File? get readyApk => null;

  @override
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    File? existingApk,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final url = Uri.tryParse(info.downloadUrl);
    if (url == null) throw StateError('更新链接无效');
    
    final nav = ExternalNavigator.current();
    final opened = await nav.open(url);
    if (!opened) {
      throw StateError('无法打开应用市场或链接，请手动更新');
    }
    return AppUpdateActionResult.success;
  }
}

class AndroidApkUpdateAction implements AppUpdateAction {
  final AppInstaller _installer;
  final AppUpdateDownloadService _downloadService;

  AndroidApkUpdateAction(this._installer, this._downloadService);

  File? _downloadedApk;

  @override
  File? get readyApk => _downloadedApk;

  @override
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    File? existingApk,
    void Function(AppDownloadProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // 1. Download or use existing
    File? apk = existingApk;
    if (apk == null || !await apk.exists()) {
      try {
        apk = await _downloadService.download(
          url: info.downloadUrl,
          expectedSize: info.fileSize,
          expectedSha256: info.sha256.toLowerCase(),
          cancelToken: cancelToken,
          onProgress: onProgress,
        );
      } catch (e) {
        if (cancelToken?.isCancelled ?? false) {
          throw StateError('用户暂停下载');
        }
        rethrow;
      }
    }

    _downloadedApk = apk;

    // 2. Check Permission
    if (!await _installer.canInstallPackages()) {
      await _installer.openInstallPermissionSettings();
      return AppUpdateActionResult.needPermission;
    }

    // 3. Install
    try {
      await _installer.installApk(apk);
      _downloadedApk = null;
      return AppUpdateActionResult.success;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '无法打开系统安装器');
    }
  }
}
