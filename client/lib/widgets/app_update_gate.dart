import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_info.dart';
import '../services/app_update_coordinator.dart';
import '../services/app_update_download_service.dart';

/// 根级更新门禁。它包裹登录页与首页，因此 required 状态不能通过返回、切换
/// 页面或未登录路径绕过；普通更新仅在首次发现时提示一次，仍可继续使用 App。
class AppUpdateGate extends StatefulWidget {
  final Widget child;

  const AppUpdateGate({super.key, required this.child});

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate>
    with WidgetsBindingObserver {
  bool _optionalDialogVisible = false;
  int? _presentedOptionalVersion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppUpdateCoordinator>().initialize();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<AppUpdateCoordinator>().onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = context.watch<AppUpdateCoordinator>();
    final info = coordinator.info;
    if (coordinator.phase != AppUpdatePhase.optional) {
      _presentedOptionalVersion = null;
    }
    if (coordinator.phase == AppUpdatePhase.optional &&
        info != null &&
        _presentedOptionalVersion != info.latestVersionCode) {
      _presentedOptionalVersion = info.latestVersionCode;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _showOptionalDialog());
    }

    return Stack(
      children: [
        widget.child,
        if (coordinator.isBlocking)
          Positioned.fill(
            child: PopScope(
              canPop: false,
              child: AppUpdateScreen(coordinator: coordinator),
            ),
          ),
      ],
    );
  }

  Future<void> _showOptionalDialog() async {
    if (!mounted || _optionalDialogVisible) return;
    final coordinator = context.read<AppUpdateCoordinator>();
    if (coordinator.phase != AppUpdatePhase.optional ||
        coordinator.info == null) {
      return;
    }
    _optionalDialogVisible = true;
    final action = await showDialog<_OptionalUpdateAction>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => _OptionalUpdateDialog(
        info: coordinator.info!,
        onLater: () =>
            Navigator.of(dialogContext).pop(_OptionalUpdateAction.later),
        onIgnore: () =>
            Navigator.of(dialogContext).pop(_OptionalUpdateAction.ignore),
        onUpdate: () =>
            Navigator.of(dialogContext).pop(_OptionalUpdateAction.update),
      ),
    );
    _optionalDialogVisible = false;
    if (!mounted || coordinator.phase != AppUpdatePhase.optional) return;

    switch (action) {
      case _OptionalUpdateAction.update:
        await coordinator.downloadOrInstall();
      case _OptionalUpdateAction.ignore:
        await coordinator.ignoreOptionalUpdate();
      case _OptionalUpdateAction.later:
      case null:
        await coordinator.deferOptionalUpdate();
    }
  }
}

enum _OptionalUpdateAction { later, ignore, update }

class _OptionalUpdateDialog extends StatelessWidget {
  final AppUpdateInfo info;
  final VoidCallback onLater;
  final VoidCallback onIgnore;
  final VoidCallback onUpdate;

  const _OptionalUpdateDialog({
    required this.info,
    required this.onLater,
    required this.onIgnore,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.system_update_alt_rounded,
              color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text('发现新版本 ${info.latestVersionName}')),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 300),
        child: SingleChildScrollView(
          child: Text(info.changelog.isEmpty ? '本次更新优化了使用体验。' : info.changelog),
        ),
      ),
      actions: [
        TextButton(onPressed: onIgnore, child: const Text('忽略此版本')),
        TextButton(onPressed: onLater, child: const Text('稍后')),
        FilledButton(onPressed: onUpdate, child: const Text('立即更新')),
      ],
    );
  }
}

/// 全屏更新页，覆盖冷启动检查、强制更新、下载、校验完成和唤起安装器的状态。
class AppUpdateScreen extends StatelessWidget {
  final AppUpdateCoordinator coordinator;

  const AppUpdateScreen({super.key, required this.coordinator});

  @override
  Widget build(BuildContext context) {
    final info = coordinator.info;
    final phase = coordinator.phase;
    final theme = Theme.of(context);
    final progress = coordinator.downloadProgress;
    final isInitial = phase == AppUpdatePhase.initializing ||
        phase == AppUpdatePhase.checking;
    final isDownloading = phase == AppUpdatePhase.downloading;
    final isInstalling = phase == AppUpdatePhase.installing;
    final canDownload = info != null && info.updateAvailable && !isInitial;

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 36, 28, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.system_update_rounded,
                    size: 48,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    isInitial
                        ? '正在检查更新'
                        : info == null
                            ? '需要更新应用'
                            : info.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _description(phase, info),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (isDownloading) ...[
                    const SizedBox(height: 28),
                    LinearProgressIndicator(value: progress?.percent),
                    const SizedBox(height: 10),
                    Text(
                      _progressText(progress),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (info?.changelog.isNotEmpty == true) ...[
                    const SizedBox(height: 28),
                    Text('更新内容', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Text(info!.changelog,
                            style: theme.textTheme.bodyMedium),
                      ),
                    ),
                  ] else
                    const Spacer(),
                  if (coordinator.errorMessage != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      coordinator.errorMessage!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: isInitial || isDownloading || isInstalling
                        ? null
                        : canDownload
                            ? coordinator.downloadOrInstall
                            : () =>
                                coordinator.check(force: true, manual: true),
                    child: Text(_primaryActionText(phase, canDownload)),
                  ),
                  if (isDownloading && !coordinator.isRequired) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: coordinator.cancelDownload,
                      child: const Text('暂停下载'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _description(AppUpdatePhase phase, AppUpdateInfo? info) {
    switch (phase) {
      case AppUpdatePhase.initializing:
      case AppUpdatePhase.checking:
        return '请稍候';
      case AppUpdatePhase.downloading:
        return '正在下载并校验安装包';
      case AppUpdatePhase.readyToInstall:
        return '安装包已准备完成';
      case AppUpdatePhase.installing:
        return '请在系统安装界面完成更新';
      case AppUpdatePhase.required:
        return info == null ? '请重新检查更新信息' : '当前版本已停止服务，请更新后继续使用';
      case AppUpdatePhase.allowed:
      case AppUpdatePhase.optional:
        return '发现新版本';
    }
  }

  String _primaryActionText(AppUpdatePhase phase, bool canDownload) {
    switch (phase) {
      case AppUpdatePhase.readyToInstall:
        return '继续安装';
      case AppUpdatePhase.installing:
        return '已打开系统安装器';
      case AppUpdatePhase.required:
        return canDownload ? '立即更新' : '重新检查';
      case AppUpdatePhase.initializing:
      case AppUpdatePhase.checking:
        return '正在检查';
      case AppUpdatePhase.downloading:
        return '正在下载';
      case AppUpdatePhase.allowed:
      case AppUpdatePhase.optional:
        return '立即更新';
    }
  }

  String _progressText(AppDownloadProgress? progress) {
    if (progress == null) return '正在连接服务器';
    final received = _formatBytes(progress.receivedBytes);
    final total = _formatBytes(progress.totalBytes);
    if (progress.bytesPerSecond <= 0) return '$received / $total';
    return '$received / $total  ${_formatBytes(progress.bytesPerSecond)}/s';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
