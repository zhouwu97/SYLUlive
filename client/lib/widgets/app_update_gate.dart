import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_info.dart';
import '../platform/contracts/external_navigator.dart';
import '../platform/update_download_bridge.dart';
import '../services/app_update_coordinator.dart';

const _githubReleasesUrl = 'https://github.com/zhouwu97/SYLUlive/releases';

/// 根级更新提示协调器。它只在需要用户决策时呈现紧凑 Dialog，下载始终留在后台。
class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({
    super.key,
    required this.child,
    required this.navigatorKey,
  });

  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate>
    with WidgetsBindingObserver {
  bool _optionalDialogVisible = false;
  bool _requiredDialogVisible = false;
  int? _presentedOptionalVersion;
  int? _presentedRequiredVersion;
  int? _presentedFailedVersion;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<AppUpdateCoordinator>().onAppResumed();
    } else if (state == AppLifecycleState.paused) {
      context.read<AppUpdateCoordinator>().onAppBackgrounded();
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = context.watch<AppUpdateCoordinator>();
    final info = coordinator.info;
    if (info != null &&
        coordinator.shouldPromptOptional &&
        _presentedOptionalVersion != info.latestVersionCode) {
      _presentedOptionalVersion = info.latestVersionCode;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _showOptionalDialog());
    }
    if (info != null &&
        coordinator.isRequired &&
        _presentedRequiredVersion != info.latestVersionCode) {
      _presentedRequiredVersion = info.latestVersionCode;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _showRequiredDialog());
    }
    if (info != null &&
        coordinator.downloadState == AppUpdateDownloadState.failed &&
        coordinator.downloadStatus.userInitiated &&
        _presentedFailedVersion != info.latestVersionCode) {
      _presentedFailedVersion = info.latestVersionCode;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showFailedDialog());
    }

    return Stack(
      children: [
        widget.child,
        if (coordinator.isRequired && info != null)
          _RequiredDownloadBanner(info: info, coordinator: coordinator),
      ],
    );
  }

  BuildContext? get _dialogContext =>
      widget.navigatorKey.currentState?.overlay?.context;

  Future<void> _showOptionalDialog() async {
    if (!mounted || _optionalDialogVisible) return;
    final coordinator = context.read<AppUpdateCoordinator>();
    final info = coordinator.info;
    if (info == null || !coordinator.shouldPromptOptional) return;
    final dialogContext = _dialogContext;
    if (dialogContext == null) return _retryLater(_showOptionalDialog);

    _optionalDialogVisible = true;
    final action = await showDialog<_UpdateDialogAction>(
      context: dialogContext,
      builder: (_) => _UpdateDialog(
        info: info,
        required: false,
        downloadStatus: coordinator.downloadStatus,
      ),
    );
    _optionalDialogVisible = false;
    if (!mounted) return;
    switch (action) {
      case _UpdateDialogAction.download:
        await coordinator.enqueueDownload(wifiOnly: false, userInitiated: true);
      case _UpdateDialogAction.currentNetwork:
        await coordinator.enqueueDownload(wifiOnly: false, userInitiated: true);
      case _UpdateDialogAction.install:
        await coordinator.installPreparedUpdate();
      case _UpdateDialogAction.github:
        await _openGithub();
        await coordinator.deferOptionalUpdate();
      case _UpdateDialogAction.later:
      case null:
        await coordinator.deferOptionalUpdate();
    }
  }

  Future<void> _showRequiredDialog() async {
    if (!mounted || _requiredDialogVisible) return;
    final coordinator = context.read<AppUpdateCoordinator>();
    final info = coordinator.info;
    if (info == null || !coordinator.isRequired) return;
    final dialogContext = _dialogContext;
    if (dialogContext == null) return _retryLater(_showRequiredDialog);

    _requiredDialogVisible = true;
    final action = await showDialog<_UpdateDialogAction>(
      context: dialogContext,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: _UpdateDialog(
          info: info,
          required: true,
          downloadStatus: coordinator.downloadStatus,
        ),
      ),
    );
    _requiredDialogVisible = false;
    if (!mounted) return;
    switch (action) {
      case _UpdateDialogAction.download:
        await coordinator.enqueueDownload(wifiOnly: false, userInitiated: true);
      case _UpdateDialogAction.currentNetwork:
        await coordinator.enqueueDownload(wifiOnly: false, userInitiated: true);
      case _UpdateDialogAction.install:
        await coordinator.installPreparedUpdate();
      case _UpdateDialogAction.github:
        await _openGithub();
      case _UpdateDialogAction.later:
      case null:
        break;
    }
  }

  Future<void> _showFailedDialog() async {
    if (!mounted) return;
    final coordinator = context.read<AppUpdateCoordinator>();
    final info = coordinator.info;
    if (info == null ||
        coordinator.downloadState != AppUpdateDownloadState.failed ||
        !coordinator.downloadStatus.userInitiated) {
      return;
    }
    final dialogContext = _dialogContext;
    if (dialogContext == null) return _retryLater(_showFailedDialog);
    final retry = await showDialog<bool>(
      context: dialogContext,
      builder: (_) => AlertDialog(
        title: const Text('更新包下载失败'),
        content: const Text('可以稍后重试，也可以前往 GitHub Releases 手动下载。'),
        actions: [
          TextButton(
            onPressed: () async {
              await _openGithub();
              if (dialogContext.mounted) Navigator.of(dialogContext).pop(false);
            },
            child: const Text('GitHub 下载'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('立即重试'),
          ),
        ],
      ),
    );
    if (retry == true) {
      await coordinator.enqueueDownload(wifiOnly: false, userInitiated: true);
    }
  }

  void _retryLater(Future<void> Function() callback) {
    _retryTimer ??= Timer(const Duration(seconds: 1), () {
      _retryTimer = null;
      callback();
    });
  }

  Future<void> _openGithub() async {
    final uri = Uri.parse(_githubReleasesUrl);
    await ExternalNavigator.current().open(uri);
  }
}

enum _UpdateDialogAction { later, github, download, currentNetwork, install }

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({
    required this.info,
    required this.required,
    required this.downloadStatus,
  });

  final AppUpdateInfo info;
  final bool required;
  final NativeUpdateDownloadStatus downloadStatus;

  @override
  Widget build(BuildContext context) {
    final active = downloadStatus.isActive;
    final ready = downloadStatus.state == AppUpdateDownloadState.ready;
    return AlertDialog(
      title: Text(required ? '需要更新沈理校园' : '发现新版本 ${info.latestVersionName}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260),
        child: SingleChildScrollView(
          child: Text(
            required
                ? (ready
                    ? '当前版本已停止服务，更新包已经准备完成，请安装后继续使用。'
                    : active
                        ? '当前版本已停止服务。安装包正在后台下载 ${_progressText(downloadStatus)}，完成后可直接安装。'
                        : '当前版本已停止服务，请下载更新后继续使用。')
                : '${_sizeText(info.fileSize)}\n\n${info.changelog.isEmpty ? '本次更新优化了使用体验。' : info.changelog}',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_UpdateDialogAction.github),
          child: const Text('GitHub 下载'),
        ),
        if (!required)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_UpdateDialogAction.later),
            child: const Text('稍后'),
          ),
        if (downloadStatus.state == AppUpdateDownloadState.queued)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_UpdateDialogAction.currentNetwork),
            child: const Text('使用当前网络下载'),
          ),
        if (ready)
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_UpdateDialogAction.install),
            child: const Text('立即安装'),
          )
        else if (active && required)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(_UpdateDialogAction.later),
            child: const Text('知道了'),
          )
        else if (!active)
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_UpdateDialogAction.download),
            child: const Text('后台下载'),
          ),
      ],
    );
  }

  static String _sizeText(int bytes) =>
      '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  static String _progressText(NativeUpdateDownloadStatus status) {
    if (status.totalBytes <= 0) return '';
    return '${(status.progress * 100).toStringAsFixed(0)}%';
  }
}

class _RequiredDownloadBanner extends StatelessWidget {
  const _RequiredDownloadBanner(
      {required this.info, required this.coordinator});

  final AppUpdateInfo info;
  final AppUpdateCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    final status = coordinator.downloadStatus;
    final text = status.state == AppUpdateDownloadState.ready
        ? '版本需要更新 · 更新包已准备完成'
        : status.isActive
            ? '版本需要更新 · 正在后台下载 ${(status.progress * 100).toStringAsFixed(0)}%'
            : '版本需要更新 · 请下载新版本';
    return SafeArea(
      child: Material(
        color: Theme.of(context).colorScheme.errorContainer,
        child: InkWell(
          onTap: status.state == AppUpdateDownloadState.ready
              ? coordinator.installPreparedUpdate
              : status.isActive
                  ? null
                  : coordinator.downloadOrInstall,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.system_update_alt_rounded,
                    color: Theme.of(context).colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(child: Text(text)),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
