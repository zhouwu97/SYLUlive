import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

typedef AppComposerCanSend = bool Function(TextEditingValue value);

/// 私信与评论共用的底部输入栏外观，业务状态由使用方维护。
class AppComposerBar extends StatelessWidget {
  const AppComposerBar({
    super.key,
    required this.textController,
    required this.focusNode,
    required this.hintText,
    required this.leadingTooltip,
    required this.onLeadingPressed,
    required this.emojiPanelVisible,
    required this.onEmojiPressed,
    required this.canSend,
    required this.onSend,
    this.composerKey,
    this.leadingKey,
    this.inputContainerKey,
    this.inputKey,
    this.emojiKey,
    this.sendContainerKey,
    this.sendKey,
    this.sendTooltip = '发送',
    this.onInputTap,
    this.onKeyEvent,
    this.fieldEnabled = true,
    this.readOnly = false,
    this.leadingLoading = false,
    this.sending = false,
    this.inputFillColor,
    this.inputTextColor,
    this.hintColor,
    this.decorate = true,
  });

  final TextEditingController textController;
  final FocusNode focusNode;
  final String hintText;
  final String leadingTooltip;
  final VoidCallback? onLeadingPressed;
  final bool emojiPanelVisible;
  final VoidCallback? onEmojiPressed;
  final AppComposerCanSend canSend;
  final VoidCallback? onSend;
  final String sendTooltip;
  final VoidCallback? onInputTap;
  final KeyEventResult Function(FocusNode node, KeyEvent event)? onKeyEvent;
  final bool fieldEnabled;
  final bool readOnly;
  final bool leadingLoading;
  final bool sending;
  final Color? inputFillColor;
  final Color? inputTextColor;
  final Color? hintColor;
  final bool decorate;
  final Key? composerKey;
  final Key? leadingKey;
  final Key? inputContainerKey;
  final Key? inputKey;
  final Key? emojiKey;
  final Key? sendContainerKey;
  final Key? sendKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: composerKey,
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      decoration: decorate
          ? BoxDecoration(
              color: colors.surface,
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            key: leadingKey,
            width: 44,
            height: 44,
            child: IconButton(
              tooltip: leadingTooltip,
              onPressed: onLeadingPressed,
              padding: EdgeInsets.zero,
              icon: leadingLoading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_rounded, size: 25),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Focus(
              onKeyEvent: onKeyEvent,
              child: Container(
                key: inputContainerKey,
                constraints: const BoxConstraints(minHeight: 46),
                child: TextField(
                  key: inputKey,
                  controller: textController,
                  focusNode: focusNode,
                  onTap: onInputTap,
                  enabled: fieldEnabled,
                  readOnly: readOnly,
                  style: TextStyle(color: inputTextColor ?? colors.onSurface),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: hintText,
                    isDense: true,
                    filled: true,
                    fillColor: inputFillColor ?? colors.surfaceContainerHighest,
                    hintStyle: TextStyle(
                      color: hintColor ?? colors.onSurfaceVariant,
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 44,
                      maxWidth: 44,
                      minHeight: 46,
                      maxHeight: 46,
                    ),
                    suffixIcon: SizedBox(
                      key: emojiKey,
                      width: 44,
                      height: 44,
                      child: IconButton(
                        tooltip: emojiPanelVisible ? '打开键盘' : '选择表情',
                        onPressed: onEmojiPressed,
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          emojiPanelVisible
                              ? Icons.keyboard_alt_outlined
                              : Icons.sentiment_satisfied_alt_outlined,
                          size: 22,
                        ),
                      ),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(23),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: textController,
            builder: (context, value, _) {
              final sendEnabled = !sending && canSend(value);
              return SizedBox(
                key: sendContainerKey,
                width: 44,
                height: 44,
                child: IconButton.filled(
                  key: sendKey,
                  tooltip: sendTooltip,
                  onPressed: sendEnabled ? onSend : null,
                  style: IconButton.styleFrom(
                    fixedSize: const Size(44, 44),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: colors.onPrimary,
                    disabledBackgroundColor:
                        colors.onSurface.withValues(alpha: 0.12),
                    disabledForegroundColor:
                        colors.onSurface.withValues(alpha: 0.38),
                  ),
                  icon: sending
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: colors.onPrimary,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 20),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
