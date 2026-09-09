import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_info.dart';
import '../platform/contracts/external_navigator.dart';
import '../platform/update_download_bridge.dart';
import '../services/app_update_coordinator.dart';

const githubReleasesUrl = 'https://github.com/zhouwu97/SYLUlive/releases';

/// 手动检查将本地 ready / downloading 视为一等结果，避免重复下载同一 release。
class UpdateChecker {
  static Future<void> check(
    BuildContext context, {
    bool showNoUpdateToast = false,
    bool manual = false,
  }) async {
    final coordinator = context.read<AppUpdateCoordinator>();
    await coordinator.check(force: true, manual: manual);
    if (!context.mounted || !manual) {
      if (showNoUpdateToast &&
          context.mounted &&
          coordinator.info?.updateType == AppUpdateType.none) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前已经是最新版本')));
      }
      return;
    }

    final info = coordinator.info;
    if (info == null || info.updateType == AppUpdateType.none) {
      // 手动检查可能来自模态面板，根级弹窗才能显示在面板上方。
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => AlertDialog(
          title: const Text('检查更新'),
          content: const Text('当前已经是最新版本'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    final status = coordinator.downloadStatus;
    if (status.state == AppUpdateDownloadState.ready) {
      await _showReady(context, coordinator, info);
    } else if (status.isActive) {
      await _showDownloading(context, coordinator, info, status);
    } else {
      await _showAvailable(context, coordinator, info);
    }
  }

  static Future<void> _showReady(
    BuildContext context,
    AppUpdateCoordinator coordinator,
    AppUpdateInfo info,
  ) async {
    final install = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('沈理校园 ${info.latestVersionName} 已准备好'),
        content: const Text('更新包已经下载并校验完成，现在安装吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('立即安装')),
        ],
      ),
    );
    if (install == true) await coordinator.installPreparedUpdate();
  }

  static Future<void> _showDownloading(
    BuildContext context,
    AppUpdateCoordinator coordinator,
    AppUpdateInfo info,
    NativeUpdateDownloadStatus status,
  ) async {
    final useCurrentNetwork = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('沈理校园 ${info.latestVersionName} 正在后台下载'),
        content: Text(
          '${_size(status.receivedBytes)} / ${_size(status.totalBytes)}'
          '${status.bytesPerSecond > 0 ? ' · ${_size(status.bytesPerSecond)}/s' : ''}\n\n可以继续正常使用应用。',
        ),
        actions: [
          const TextButton(onPressed: _openGithub, child: Text('GitHub 下载')),
          if (status.state == AppUpdateDownloadState.queued)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('使用当前网络下载'),
            ),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了')),
        ],
      ),
    );
    if (useCurrentNetwork == true) {
      await coordinator.enqueueDownload(wifiOnly: false, userInitiated: true);
    }
  }

  static Future<void> _showAvailable(
    BuildContext context,
    AppUpdateCoordinator coordinator,
    AppUpdateInfo info,
  ) async {
    final download = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('发现新版本 ${info.latestVersionName}'),
        content: Text(
            '${_size(info.fileSize)}\n\n${info.changelog.isEmpty ? '本次更新优化了使用体验。' : info.changelog}'),
        actions: [
          const TextButton(onPressed: _openGithub, child: Text('GitHub 下载')),
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('后台下载')),
        ],
      ),
    );
    if (download == true) {
      await coordinator.enqueueDownload(wifiOnly: false, userInitiated: true);
    }
  }

  static Future<void> _openGithub() =>
      ExternalNavigator.current().open(Uri.parse(githubReleasesUrl));

  static String _size(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
