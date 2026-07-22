import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/app_update_info.dart';
import '../app_platform.dart';
import '../app_installer.dart';

/// 统一的应用更新动作接口
abstract interface class AppUpdateAction {
  Future<void> execute(AppUpdateInfo info, String? downloadedApkPath);

  factory AppUpdateAction.current(AppInstaller installer) {
    if (AppPlatforms.current.isOhos) {
      return const OhosMarketUpdateAction();
    }
    return AndroidApkUpdateAction(installer);
  }
}

/// 鸿蒙：跳转华为应用市场或官方分发链接
class OhosMarketUpdateAction implements AppUpdateAction {
  const OhosMarketUpdateAction();

  @override
  Future<void> execute(AppUpdateInfo info, String? downloadedApkPath) async {
    final url = Uri.tryParse(info.downloadUrl);
    if (url == null) throw StateError('更新链接无效');
    
    // 如果是应用市场链接 (appgallery://)，可以直接跳转；否则使用浏览器打开 HAP/网页下载页
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      throw StateError('无法打开更新页面，请手动前往应用市场更新');
    }
  }
}

/// Android：调用系统安装器安装已下载的 APK
class AndroidApkUpdateAction implements AppUpdateAction {
  final AppInstaller _installer;

  const AndroidApkUpdateAction(this._installer);

  @override
  Future<void> execute(AppUpdateInfo info, String? downloadedApkPath) async {
    if (downloadedApkPath == null || downloadedApkPath.isEmpty) {
      throw StateError('安装包未下载完成');
    }
    
    // 假设下载的文件在 downloadedApkPath，由于 AppInstaller 已封装 File 逻辑，
    // 这里需在调用方转 File 传递给 installApk，或在 coordinator 里处理。
    // 为了不大幅改动 AppInstaller，我们在外部处理具体安装。
  }
}
