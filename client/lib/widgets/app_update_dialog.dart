import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_info.dart';
import '../platform/app_platform.dart';
import '../platform/contracts/external_navigator.dart';
import '../platform/contracts/update_action.dart';
import '../platform/update_download_bridge.dart';
import '../services/app_update_coordinator.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme_tokens.dart';
import 'app_dialog.dart';
import 'app_release_dialog.dart';

Future<void> showAppUpdateDialog(
    BuildContext context, AppUpdateCoordinator coordinator, AppUpdateInfo info,
    {bool required = false, bool callerOwnsPrompt = false}) async {
  if (!callerOwnsPrompt && !coordinator.tryBeginPrompt()) return;
  try {
    if (required) coordinator.markRequiredPromptPresented();
    if (coordinator.downloadState == AppUpdateDownloadState.failed) {
      coordinator.markFailurePromptPresented();
    }
    await coordinator.deferOptionalUpdate();
    if (coordinator.hasReadyPackage) coordinator.deferInstallPrompt();
    if (!context.mounted) return;
    await showAppDialog<void>(
      context: context,
      barrierDismissible: !required,
      builder: (dialogContext) {
        final current = dialogContext.watch<AppUpdateCoordinator>();
        if (current.isRequired != required ||
            current.info?.releaseKey != info.releaseKey) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (dialogContext.mounted &&
                ModalRoute.of(dialogContext)?.isCurrent == true) {
              Navigator.of(dialogContext).pop();
            }
          });
        }
        return PopScope(
          canPop: !required,
          child: AppUpdateDialog(info: info, required: required),
        );
      },
    );
  } finally {
    if (coordinator.info?.releaseKey == info.releaseKey) {
      if (coordinator.hasReadyPackage) coordinator.deferInstallPrompt();
      if (coordinator.downloadState == AppUpdateDownloadState.failed) {
        coordinator.markFailurePromptPresented();
      }
    }
    if (!callerOwnsPrompt) coordinator.endPrompt();
  }
}

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({super.key, required this.info, this.required = false});

  final AppUpdateInfo info;
  final bool required;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _busy = false;
  String? _actionError;

  bool get _isCurrent => mounted && ModalRoute.of(context)?.isCurrent == true;

  void _close() => Navigator.of(context).pop();

  Future<void> _act({bool github = false}) async {
    if (_busy) return;
    final coordinator = context.read<AppUpdateCoordinator>();
    if (coordinator.info?.releaseKey != widget.info.releaseKey) return;
    final external =
        widget.info.deliveryMode == AppUpdateDeliveryMode.externalMarket;
    final ready = coordinator.hasReadyPackage;
    if (!github &&
        !external &&
        coordinator.isDownloading &&
        coordinator.downloadState != AppUpdateDownloadState.queued) {
      _close();
      return;
    }
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      if (github) {
        if (!await ExternalNavigator.current()
            .open(Uri.parse(appReleaseDownloadPage))) {
          throw StateError('download page unavailable');
        }
      } else if (external) {
        final action = AppPlatforms.current.isIOS
            ? const IOSAppStoreUpdateAction()
            : const OhosMarketUpdateAction();
        await action.execute(widget.info);
      } else if (ready) {
        coordinator.deferInstallPrompt();
        await coordinator.installPreparedUpdate();
      } else {
        await coordinator.enqueueDownload(wifiOnly: false, userInitiated: true);
        if (coordinator.hasReadyPackage) coordinator.deferInstallPrompt();
        if (widget.required || coordinator.hasReadyPackage) return;
      }
      if (_isCurrent) _close();
    } catch (_) {
      if (mounted) {
        setState(() => _actionError = github
            ? '无法打开下载页面，请重试'
            : external
                ? '无法打开应用市场，请重试'
                : ready
                    ? '无法打开安装程序，请重试'
                    : '无法开始下载，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppThemeTokens.of(context);
    final coordinator = context.watch<AppUpdateCoordinator>();
    final status = coordinator.downloadStatus;
    final external =
        widget.info.deliveryMode == AppUpdateDeliveryMode.externalMarket;
    final ready = !external && status.state == AppUpdateDownloadState.ready;
    final active = !external && status.isActive;
    final failed = !external && status.state == AppUpdateDownloadState.failed;
    final paused = !external && status.state == AppUpdateDownloadState.paused;
    final title = widget.required
        ? '需要更新沈理校园'
        : ready
            ? '新版本已准备好'
            : active
                ? '正在准备新版本'
                : failed
                    ? '更新包下载失败'
                    : paused
                        ? '更新下载已暂停'
                        : '发现新版本 ${widget.info.latestVersionName}';
    final badge = widget.required
        ? '正式版 · 需要更新'
        : ready
            ? '正式版 · 已准备好'
            : active
                ? '正式版 · 下载中'
                : '正式版 · 新版本';
    final label = external
        ? (AppPlatforms.current.isIOS ? '打开 App Store / TestFlight' : '打开应用市场')
        : ready
            ? '立即安装'
            : status.state == AppUpdateDownloadState.queued
                ? '使用当前网络下载'
                : active
                    ? '知道了'
                    : failed
                        ? '立即重试'
                        : paused
                            ? '继续下载'
                            : '下载更新';
    final primary = FilledButton.icon(
      onPressed: _busy ? null : _act,
      style: FilledButton.styleFrom(
        foregroundColor: colors.onPrimary,
        backgroundColor: colors.primary,
        minimumSize: const Size.fromHeight(48),
        visualDensity: VisualDensity.standard,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      ),
      icon: Icon(
          external
              ? Icons.open_in_new_rounded
              : ready
                  ? Icons.check_rounded
                  : active
                      ? Icons.check_rounded
                      : failed
                          ? Icons.refresh_rounded
                          : Icons.download_outlined,
          size: 18),
      label: Text(_busy ? '正在打开…' : label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
    );
    final secondary = widget.required && external
        ? null
        : TextButton(
            onPressed: widget.required
                ? (_busy ? null : () => _act(github: true))
                : _close,
            style: TextButton.styleFrom(
              foregroundColor: colors.textPrimary,
              backgroundColor: colors.surfaceMuted,
              minimumSize: const Size.fromHeight(48),
              visualDensity: VisualDensity.standard,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13)),
            ),
            child: Text(
                widget.required
                    ? 'GitHub 下载'
                    : ready
                        ? '稍后安装'
                        : active
                            ? '关闭'
                            : '稍后',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          );

    return AppReleaseDialog(
      info: widget.info,
      badge: badge,
      subtitle: ready
          ? '下载完成，随时安装'
          : widget.required
              ? '保持软件正常使用'
              : '发现更好的使用体验',
      icon: ready ? Icons.check_rounded : Icons.download_outlined,
      title: title,
      onClose: widget.required ? null : _close,
      notice: _notice(colors, status, external),
      notesTitle: '本次更新',
      emptyNotes: '本次更新优化了使用体验。',
      bottomNote: widget.required
          ? '安装更新后可恢复正常使用。'
          : ready
              ? '稍后安装不影响继续使用当前版本。'
              : '可以继续正常使用应用。',
      footer: Column(mainAxisSize: MainAxisSize.min, children: [
        LayoutBuilder(builder: (context, constraints) {
          if (secondary == null) {
            return SizedBox(width: double.infinity, child: primary);
          }
          if (constraints.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(14) > 18) {
            return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [primary, const SizedBox(height: 12), secondary]);
          }
          return Row(children: [
            SizedBox(width: 104, child: secondary),
            const SizedBox(width: 12),
            Expanded(child: primary)
          ]);
        }),
        if (_actionError != null) ...[
          const SizedBox(height: 10),
          Semantics(
              liveRegion: true,
              child: Text(_actionError!,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color:
                          Color.lerp(colors.error, colors.textPrimary, 0.25)))),
        ],
        if (!widget.required && !external && !ready) ...[
          const SizedBox(height: 8),
          TextButton.icon(
              onPressed: _busy ? null : () => _act(github: true),
              iconAlignment: IconAlignment.end,
              icon: const Icon(Icons.north_east_rounded, size: 14),
              label: const Text('GitHub 下载', style: TextStyle(fontSize: 12))),
        ] else ...[
          const SizedBox(height: 16),
          Text(widget.required ? '当前版本需要升级后才能继续使用' : '由你决定何时安装',
              style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  fontWeight: FontWeight.w400,
                  color: colors.textSecondary)),
          const SizedBox(height: 8),
        ],
      ]),
    );
  }

  Widget _notice(
      AppThemeTokens colors, NativeUpdateDownloadStatus status, bool external) {
    final ready = !external && status.state == AppUpdateDownloadState.ready;
    final failed = !external && status.state == AppUpdateDownloadState.failed;
    final warning = widget.required && !ready;
    final title = external
        ? '请前往应用市场更新'
        : ready
            ? '安装包已下载并校验完成'
            : status.state == AppUpdateDownloadState.queued
                ? (status.wifiOnly ? '等待 WLAN 后下载' : '正在排队下载')
                : status.state == AppUpdateDownloadState.downloading
                    ? '正在后台下载'
                    : status.state == AppUpdateDownloadState.verifying
                        ? '正在校验更新包'
                        : failed
                            ? '下载未完成，请检查网络后重试。'
                            : status.state == AppUpdateDownloadState.paused
                                ? '可继续下载已暂停的安装包'
                                : widget.required
                                    ? '当前版本已停止服务'
                                    : '发现可下载的正式版';
    final detail = ready
        ? '确认后即可打开系统安装程序。'
        : widget.required
            ? '请更新后继续使用。'
            : '下载完成后，由你决定何时安装。';
    final accent = failed
        ? colors.error
        : warning
            ? (colors.isDark
                ? const Color(0xFFF5C36E)
                : const Color(0xFF9C6100))
            : colors.primary;
    return Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: failed
                  ? (colors.isDark
                      ? AppColors.dangerSurfaceDark
                      : AppColors.dangerSurfaceLight)
                  : warning
                      ? (colors.isDark
                          ? AppColors.warningSurfaceDark
                          : AppColors.warningSurfaceLight)
                      : colors.primaryContainer,
              borderRadius: BorderRadius.circular(12)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(ready ? Icons.check_rounded : Icons.info_outline_rounded,
                  size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            fontWeight: FontWeight.w500,
                            color: colors.textPrimary)),
                    const SizedBox(height: 6),
                    Text(detail,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            fontWeight: FontWeight.w400,
                            color: colors.textSecondary)),
                  ])),
            ]),
            if (status.state == AppUpdateDownloadState.downloading &&
                !external) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                  value: status.totalBytes > 0 ? status.progress : null,
                  minHeight: 4,
                  borderRadius: BorderRadius.circular(4)),
              const SizedBox(height: 8),
              Text(
                  '${formatReleaseSize(status.receivedBytes)} / ${formatReleaseSize(status.totalBytes)}'
                  '${status.totalBytes > 0 ? ' · ${(status.progress * 100).toStringAsFixed(0)}%' : ''}',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      fontWeight: FontWeight.w400,
                      color: accent)),
            ],
          ]),
        ));
  }
}
