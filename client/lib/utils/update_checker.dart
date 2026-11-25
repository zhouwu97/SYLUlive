import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_info.dart';
import '../services/app_update_coordinator.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_release_dialog.dart' show appReleaseDownloadPage;
import '../widgets/app_update_dialog.dart';
import '../widgets/beta_download_dialog.dart';

const githubReleasesUrl = appReleaseDownloadPage;

/// 手动检查从请求开始到结果关闭共用一次展示，避免多个入口叠窗。
class UpdateChecker {
  static Future<void> check(
    BuildContext context, {
    bool showNoUpdateToast = false,
    bool manual = false,
  }) async {
    final coordinator = context.read<AppUpdateCoordinator>();
    if (manual && !coordinator.tryBeginPrompt()) return;
    var retry = false;
    try {
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

      coordinator.deferBetaDownload();
      final info = coordinator.info;
      if (coordinator.errorMessage != null) {
        retry =
            await _showFailure(context, '检查更新失败', coordinator.errorMessage!);
        return;
      }
      if (info == null || info.updateType == AppUpdateType.none) {
        final beta = coordinator.betaInfo;
        if (beta != null) {
          await showBetaDownloadDialog(context, coordinator, beta,
              callerOwnsPrompt: true);
          return;
        }
        if (coordinator.betaErrorMessage != null) {
          retry = await _showFailure(context, '检查 Beta 下载失败',
              '当前正式版已是最新版本。\n${coordinator.betaErrorMessage}');
          return;
        }
        // 检查入口可位于关于面板，结果需要覆盖在根导航上。
        await showAppDialog<void>(
          context: context,
          useRootNavigator: true,
          builder: (dialogContext) => AppAlertDialog(
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
      await showAppUpdateDialog(context, coordinator, info,
          required: coordinator.isRequired, callerOwnsPrompt: true);
    } finally {
      if (manual) {
        coordinator.endPrompt();
        if (retry && context.mounted) {
          unawaited(check(context, manual: true));
        }
      }
    }
  }

  static Future<bool> _showFailure(
          BuildContext context, String title, String message) async =>
      await showAppDialog<bool>(
        context: context,
        useRootNavigator: true,
        builder: (dialogContext) => AppAlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('重试'),
            ),
          ],
        ),
      ) ??
      false;
}
