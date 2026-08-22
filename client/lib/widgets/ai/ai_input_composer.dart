import 'package:flutter/material.dart';

import '../../providers/ai_assistant_provider.dart';
import '../campus/campus_theme.dart';

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
  final VoidCallback? onAgentPermissionTap;

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
    this.onAgentPermissionTap,
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
    final composerSurface = isDark
        ? colors.primaryContainer.withValues(alpha: 0.72)
        : CampusTheme.primaryLight;
    final composerBorder =
        isDark ? Colors.white.withValues(alpha: 0.10) : CampusTheme.border;

    return SafeArea(
      top: false,
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showAgentPermissionMode)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: AiAgentPermissionModeBar(
                  trusted: widget.agentTrusted,
                  onTap: widget.onAgentPermissionTap,
                ),
              ),
            Container(
              height: 48,
              padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
              decoration: BoxDecoration(
                color: composerSurface,
                borderRadius: BorderRadius.circular(24),
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
                        hintText: widget.enabled ? widget.hintText : '基础设施测试中',
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
    this.onTap,
  });

  final bool trusted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final surface = colors.surfaceContainerHighest.withValues(alpha: 0.7);
    return Semantics(
      button: true,
      label: trusted ? '校园 Agent 权限：完全信任' : '校园 Agent 权限：每次询问',
      hint: '点击打开 Agent 权限设置',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: surface,
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _ModeLabel(
                    label: '每次询问',
                    selected: !trusted,
                    colors: colors,
                  ),
                ),
                Expanded(
                  child: _ModeLabel(
                    label: '完全信任',
                    selected: trusted,
                    colors: colors,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.tune_rounded, size: 18, color: colors.primary),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeLabel extends StatelessWidget {
  const _ModeLabel({
    required this.label,
    required this.selected,
    required this.colors,
  });

  final String label;
  final bool selected;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      constraints: const BoxConstraints(minHeight: 32),
      decoration: BoxDecoration(
        color: selected ? colors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? colors.onPrimary : colors.onSurfaceVariant,
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}
