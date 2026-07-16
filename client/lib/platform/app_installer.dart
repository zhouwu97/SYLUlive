import 'dart:io';

import 'package:flutter/services.dart';

/// Android 系统安装器桥接。APK 仅从 App 私有 cache/app_updates 目录传给
/// FileProvider，原生侧会再次校验路径，避免把任意文件暴露给安装 Intent。
class AppInstaller {
  static const MethodChannel _channel = MethodChannel('shenliyuan/app_update');

  Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
  }

  Future<bool> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('openInstallPermissionSettings') ??
        false;
  }

  Future<void> installApk(File apkFile) async {
    if (!Platform.isAndroid) {
      throw PlatformException(
        code: 'UNSUPPORTED_PLATFORM',
        message: '应用内安装仅支持 Android',
      );
    }
    await _channel.invokeMethod<void>('installApk', {'path': apkFile.path});
  }

  Future<void> deleteDownloadedApk(File apkFile) async {
    if (!Platform.isAndroid) return;
    await _channel
        .invokeMethod<void>('deleteDownloadedApk', {'path': apkFile.path});
  }
}
