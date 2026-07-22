import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';

import '../../models/app_update_info.dart';
import '../app_platform.dart';
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
    void Function(double)? onProgress,
    CancelToken? cancelToken,
  });

  factory AppUpdateAction.current(AppInstaller installer, AppUpdateDownloadService downloadService) {
    if (AppPlatforms.current.isOhos) {
      return const OhosMarketUpdateAction();
    }
    return AndroidApkUpdateAction(installer, downloadService);
  }
}

class OhosMarketUpdateAction implements AppUpdateAction {
  const OhosMarketUpdateAction();

  @override
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    void Function(double)? onProgress,
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

  const AndroidApkUpdateAction(this._installer, this._downloadService);

  @override
  Future<AppUpdateActionResult> execute(
    AppUpdateInfo info, {
    void Function(double)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // 1. Download
    File? apk;
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

    // 2. Check Permission
    if (!await _installer.canInstallPackages()) {
      await _installer.openInstallPermissionSettings();
      return AppUpdateActionResult.needPermission;
    }

    // 3. Install
    try {
      await _installer.installApk(apk);
      return AppUpdateActionResult.success;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '无法打开系统安装器');
    }
  }
}
