import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update_info.dart';
import '../platform/app_platform.dart';
import '../platform/platform_capabilities.dart';
import '../platform/update_download_bridge.dart';
import '../services/app_update_coordinator.dart';
import 'app_update_dialog.dart';
import 'beta_download_dialog.dart';

String get _storeLabel =>
    AppPlatforms.current.isIOS ? '打开 App Store / TestFlight' : '打开应用市场';

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
  bool _betaDialogVisible = false;
  final _presentedBetaVersions = <String>{};
  final _presentedInstallVersions = <String>{};
  String? _presentedOptionalVersion;
  late bool _isForeground;
  Timer? _foregroundCheckTimer;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    final state = binding.lifecycleState;
    _isForeground = state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (_isForeground) _startForegroundChecks();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _foregroundCheckTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _isForeground = true);
      _startForegroundChecks();
      unawaited(context.read<AppUpdateCoordinator>().onAppResumed());
    } else if (state != AppLifecycleState.inactive) {
      _isForeground = false;
      _foregroundCheckTimer?.cancel();
      _foregroundCheckTimer = null;
      if (state == AppLifecycleState.paused) {
        unawaited(context.read<AppUpdateCoordinator>().onAppBackgrounded());
      }
    }
  }

  void _startForegroundChecks() {
    if (!PlatformCapabilities.current.supportsInAppPackageInstall) return;
    _foregroundCheckTimer ??= Timer.periodic(
      AppUpdateCoordinator.foregroundCheckInterval,
      (_) => unawaited(context.read<AppUpdateCoordinator>().check(force: true)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = context.watch<AppUpdateCoordinator>();
    final info = coordinator.info;
    final canPrompt = _isForeground && !coordinator.isPromptActive;
    if (canPrompt &&
        !_optionalDialogVisible &&
        !_betaDialogVisible &&
        info != null &&
        ((coordinator.shouldPromptOptional &&
                _presentedOptionalVersion != info.releaseKey) ||
            (coordinator.shouldPromptInstall &&
                !_presentedInstallVersions.contains(info.releaseKey)))) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _showOptionalDialog());
    }
    if (canPrompt &&
        info != null &&
        coordinator.shouldPromptRequired &&
        !_betaDialogVisible &&
        !_optionalDialogVisible) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _showRequiredDialog());
    }
    if (canPrompt &&
        info != null &&
        !_betaDialogVisible &&
        !_optionalDialogVisible &&
        !_requiredDialogVisible &&
        coordinator.shouldPromptFailure) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showFailedDialog());
    }
    final beta = coordinator.betaInfo;
    if (canPrompt &&
        !_optionalDialogVisible &&
        !_requiredDialogVisible &&
        !_betaDialogVisible &&
        (!coordinator.shouldPromptOptional ||
            _presentedOptionalVersion == info?.releaseKey) &&
        !coordinator.shouldPromptInstall &&
        coordinator.shouldPromptBeta &&
        beta != null &&
        !_presentedBetaVersions.contains(beta.releaseKey)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showBetaDialog());
    }

    return Stack(
      children: [
        widget.child,
        if (coordinator.isRequired && info != null)
          _RequiredDownloadBanner(
              info: info,
              coordinator: coordinator,
              onTap: () => _showRequiredDialog(fromBanner: true)),
      ],
    );
  }

  BuildContext? get _dialogContext =>
      widget.navigatorKey.currentState?.overlay?.context;

  Future<void> _showBetaDialog() async {
    if (!mounted ||
        !_isForeground ||
        _betaDialogVisible ||
        _optionalDialogVisible ||
        _requiredDialogVisible) {
      return;
    }
    final coordinator = context.read<AppUpdateCoordinator>();
    if (coordinator.isPromptActive) return;
    final beta = coordinator.betaInfo;
    if (beta == null ||
        !coordinator.shouldPromptBeta ||
        coordinator.shouldPromptInstall ||
        (coordinator.shouldPromptOptional &&
            _presentedOptionalVersion != coordinator.info?.releaseKey) ||
        _presentedBetaVersions.contains(beta.releaseKey)) {
      return;
    }
    final dialogContext = _dialogContext;
    if (dialogContext == null) return _retryLater(_showBetaDialog);
    _presentedBetaVersions.add(beta.releaseKey);
    _betaDialogVisible = true;
    try {
      await showBetaDownloadDialog(dialogContext, coordinator, beta);
    } finally {
      if (mounted) setState(() => _betaDialogVisible = false);
    }
  }

  Future<void> _showOptionalDialog() async {
    if (!mounted || !_isForeground || _optionalDialogVisible) return;
    final coordinator = context.read<AppUpdateCoordinator>();
    if (coordinator.isPromptActive) return;
    final info = coordinator.info;
    final ready = coordinator.shouldPromptInstall;
    if (info == null ||
        (ready
            ? _presentedInstallVersions.contains(info.releaseKey)
            : !coordinator.shouldPromptOptional ||
                _presentedOptionalVersion == info.releaseKey)) {
      return;
    }
    final dialogContext = _dialogContext;
    if (dialogContext == null) return _retryLater(_showOptionalDialog);

    _optionalDialogVisible = true;
    if (ready) {
      _presentedInstallVersions.add(info.releaseKey);
    } else {
      _presentedOptionalVersion = info.releaseKey;
    }
    try {
      await showAppUpdateDialog(dialogContext, coordinator, info);
    } finally {
      if (mounted) {
        if (coordinator.info?.releaseKey == info.releaseKey &&
            coordinator.hasReadyPackage) {
          _presentedInstallVersions.add(info.releaseKey);
        }
        setState(() => _optionalDialogVisible = false);
      }
    }
  }

  Future<void> _showRequiredDialog({bool fromBanner = false}) async {
    if (!mounted || !_isForeground || _requiredDialogVisible) return;
    final coordinator = context.read<AppUpdateCoordinator>();
    if (coordinator.isPromptActive) return;
    final info = coordinator.info;
    if (info == null ||
        !coordinator.isRequired ||
        (!fromBanner && !coordinator.shouldPromptRequired)) {
      return;
    }
    final dialogContext = _dialogContext;
    if (dialogContext == null) return _retryLater(_showRequiredDialog);
    _requiredDialogVisible = true;
    try {
      await showAppUpdateDialog(dialogContext, coordinator, info,
          required: true);
    } finally {
      if (mounted) setState(() => _requiredDialogVisible = false);
    }
  }

  Future<void> _showFailedDialog() async {
    if (!mounted ||
        !_isForeground ||
        _optionalDialogVisible ||
        _requiredDialogVisible) {
      return;
    }
    final coordinator = context.read<AppUpdateCoordinator>();
    if (coordinator.isPromptActive) return;
    final info = coordinator.info;
    if (info == null || !coordinator.shouldPromptFailure) {
      return;
    }
    final dialogContext = _dialogContext;
    if (dialogContext == null) return _retryLater(_showFailedDialog);
    _optionalDialogVisible = true;
    try {
      await showAppUpdateDialog(dialogContext, coordinator, info,
          required: coordinator.isRequired);
    } finally {
      if (mounted) setState(() => _optionalDialogVisible = false);
    }
  }

  void _retryLater(Future<void> Function() callback) {
    _retryTimer ??= Timer(const Duration(seconds: 1), () {
      _retryTimer = null;
      callback();
    });
  }
}

class _RequiredDownloadBanner extends StatelessWidget {
  const _RequiredDownloadBanner(
      {required this.info, required this.coordinator, required this.onTap});

  final AppUpdateInfo info;
  final AppUpdateCoordinator coordinator;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = coordinator.downloadStatus;
    final external = info.deliveryMode == AppUpdateDeliveryMode.externalMarket;
    final text = external
        ? '版本需要更新 · $_storeLabel'
        : status.state == AppUpdateDownloadState.ready
            ? '版本需要更新 · 更新包已准备完成'
            : status.isActive
                ? '版本需要更新 · 正在后台下载 ${(status.progress * 100).toStringAsFixed(0)}%'
                : '版本需要更新 · 请下载新版本';
    return SafeArea(
      child: Material(
        color: Theme.of(context).colorScheme.errorContainer,
        child: InkWell(
          onTap: onTap,
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
