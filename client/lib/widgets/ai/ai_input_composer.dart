import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';
import '../../providers/ai_assistant_provider.dart';
import '../../features/ai_device_bridge/device_tool_worker.dart';

enum AgentPermissionLoadState { loading, ask, trusted, unavailable }

class AiInputComposer extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final int maxCharacters;
  final bool enabled;
  final bool running;
  final ValueChanged<String> onSend;
  final VoidCallback? onCancel;
  final String hintText;
  final bool showAgentPermissionMode;
  final bool agentTrusted;
  final AgentPermissionLoadState agentPermissionState;
  final DeviceBridgeStatus bridgeStatus;
  final VoidCallback? onAgentPermissionTap;
  final VoidCallback? onBridgeRetry;

  const AiInputComposer({
    super.key,
    required this.controller,
    this.focusNode,
    required this.maxCharacters,
    required this.enabled,
    required this.running,
    required this.onSend,
    this.onCancel,
    required this.hintText,
    this.showAgentPermissionMode = false,
    this.agentTrusted = false,
    this.agentPermissionState = AgentPermissionLoadState.ask,
    this.bridgeStatus = DeviceBridgeStatus.unknown,
    this.onAgentPermissionTap,
    this.onBridgeRetry,
  });

  @override
  State<AiInputComposer> createState() => _AiInputComposerState();
}

class _AiInputComposerState extends State<AiInputComposer> {
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void didUpdateWidget(covariant AiInputComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {});
  }

  int get _count =>
      normalizeAiMessage(widget.controller.text).characters.length;

  void _send() {
    final normalized = normalizeAiMessage(widget.controller.text);
    setState(() {
      if (normalized.isEmpty) {
        _inlineError = '请输入问题';
      } else if (normalized.characters.length > widget.maxCharacters) {
        _inlineError = '最多输入 ${widget.maxCharacters} 个可见字符';
      } else {
        _inlineError = null;
      }
    });
    if (_inlineError == null) widget.onSend(normalized);
  }

  @override
  Widget build(BuildContext context) {
    final overLimit = _count > widget.maxCharacters;
    final canSend =
        widget.enabled && !widget.running && _count > 0 && !overLimit;
    final colors = Theme.of(context).colorScheme;
    final showCounter = _count > 0 || overLimit;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final composerSurface =
        isDark ? AppColors.composerSurfaceDark : AppColors.composerSurfaceLight;
    final composerBorder =
        isDark ? AppColors.borderNormalDark : AppColors.borderNormalLight;

    return SafeArea(
      top: false,
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 4, AppSpacing.lg, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showAgentPermissionMode)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: AiAgentPermissionModeBar(
                  trusted: widget.agentTrusted,
                  permissionState: widget.agentPermissionState,
                  bridgeStatus: widget.bridgeStatus,
                  onTap: widget.onAgentPermissionTap,
                  onBridgeRetry: widget.onBridgeRetry,
                ),
              ),
            Container(
              height: 48,
              padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
              decoration: BoxDecoration(
                color: composerSurface,
                borderRadius: BorderRadius.circular(AppRadius.pill),
                border: Border.all(color: composerBorder),
              ),
              key: const ValueKey('ai-input-composer'),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      enabled: widget.enabled && !widget.running,
                      maxLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: canSend ? (_) => _send() : null,
                      onChanged: (_) {
                        if (_inlineError != null) _inlineError = null;
                      },
                      decoration: InputDecoration(
                        hintText:
                            widget.enabled ? widget.hintText : '校园 Agent 暂不可用',
                        border: InputBorder.none,
                        isDense: true,
                        hintStyle: TextStyle(
                          color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                          fontSize: 14,
                        ),
                      ),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  if (showCounter) ...[
                    const SizedBox(width: 8),
                    Text(
                      '$_count/${widget.maxCharacters}',
                      style: TextStyle(
                        color:
                            overLimit ? colors.error : colors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: IconButton.filled(
                      onPressed: widget.running
                          ? widget.onCancel
                          : (canSend ? _send : null),
                      style: IconButton.styleFrom(
                        backgroundColor: colors.primary,
                        disabledBackgroundColor: colors.surfaceContainerHighest
                            .withValues(alpha: 0.5),
                        foregroundColor: colors.onPrimary,
                        disabledForegroundColor:
                            colors.onSurfaceVariant.withValues(alpha: 0.3),
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                      ),
                      icon: Icon(
                        widget.running
                            ? Icons.stop_rounded
                            : Icons.arrow_upward_rounded,
                        size: 20,
                      ),
                      tooltip: widget.running ? '取消回答' : '发送',
                    ),
                  ),
                ],
              ),
            ),
            if (_inlineError != null || overLimit)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 12),
                child: Text(
                  _inlineError ?? '最多输入 ${widget.maxCharacters} 个可见字符',
                  style: TextStyle(color: colors.error, fontSize: 11),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 输入框上方的轻量权限状态入口；实际策略仍由权限 Bottom Sheet 管理。
class AiAgentPermissionModeBar extends StatelessWidget {
  const AiAgentPermissionModeBar({
    super.key,
    required this.trusted,
    this.permissionState,
    this.bridgeStatus = DeviceBridgeStatus.unknown,
    this.onTap,
    this.onBridgeRetry,
  });

  final bool trusted;
  final AgentPermissionLoadState? permissionState;
  final DeviceBridgeStatus bridgeStatus;
  final VoidCallback? onTap;
  final VoidCallback? onBridgeRetry;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final state = permissionState ??
        (trusted
            ? AgentPermissionLoadState.trusted
            : AgentPermissionLoadState.ask);
    final permissionLabel = switch (state) {
      AgentPermissionLoadState.loading => '正在同步权限状态',
      AgentPermissionLoadState.trusted => '完全信任',
      AgentPermissionLoadState.ask => '每次询问',
      AgentPermissionLoadState.unavailable => '权限状态暂不可同步',
    };
    final bridgeLabel = switch (bridgeStatus) {
      DeviceBridgeStatus.connected => '设备桥接在线',
      DeviceBridgeStatus.syncing => '设备桥接同步中',
      DeviceBridgeStatus.degraded => '设备桥接异常',
      DeviceBridgeStatus.offline => '设备桥接离线',
      DeviceBridgeStatus.unknown => '设备桥接状态未知',
    };
    final bridgeColor = switch (bridgeStatus) {
      DeviceBridgeStatus.connected => AppColors.success,
      DeviceBridgeStatus.syncing ||
      DeviceBridgeStatus.degraded =>
        AppColors.warning,
      DeviceBridgeStatus.offline => AppColors.danger,
      DeviceBridgeStatus.unknown => colors.outline,
    };
    final canRetryBridge = bridgeStatus == DeviceBridgeStatus.degraded ||
        bridgeStatus == DeviceBridgeStatus.offline;
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: '校园 Agent 权限：$permissionLabel',
                hint: '点击打开 Agent 权限设置',
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 14,
                          color:
                              isDark ? colors.primary : AppColors.brandPrimary,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          permissionLabel,
                          style: TextStyle(
                            color: isDark
                                ? colors.onSurfaceVariant
                                : AppColors.textSecondaryLight,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              button: canRetryBridge,
              label: bridgeLabel,
              hint: canRetryBridge ? '点击重试设备桥接' : null,
              child: InkWell(
                onTap: canRetryBridge ? onBridgeRetry : null,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: SizedBox(
                  height: 44,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        canRetryBridge ? Icons.refresh_rounded : Icons.circle,
                        size: canRetryBridge ? 16 : 6,
                        color: bridgeColor,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        bridgeLabel,
                        style: TextStyle(
                          color: isDark
                              ? colors.onSurfaceVariant
                              : AppColors.textSecondaryLight,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
