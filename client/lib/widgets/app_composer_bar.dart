import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

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
    this.shellColor,
    this.inputFillColor,
    this.inputTextColor,
    this.hintColor,
    this.iconColor,
    this.enabledSendColor,
    this.enabledSendIconColor,
    this.disabledSendColor,
    this.disabledSendIconColor,
    this.dividerColor,
    this.decorate = true,
    this.leadingIcon = Icons.add_rounded,
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
  final Color? shellColor;
  final Color? inputFillColor;
  final Color? inputTextColor;
  final Color? hintColor;
  final Color? iconColor;
  final Color? enabledSendColor;
  final Color? enabledSendIconColor;
  final Color? disabledSendColor;
  final Color? disabledSendIconColor;
  final Color? dividerColor;
  final bool decorate;
  final IconData leadingIcon;
  final Key? composerKey;
  final Key? leadingKey;
  final Key? inputContainerKey;
  final Key? inputKey;
  final Key? emojiKey;
  final Key? sendContainerKey;
  final Key? sendKey;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveShellColor = shellColor ??
        (isDark ? AppColors.composerSurfaceDark : AppColors.composerSurfaceLight);
    final effectiveDividerColor = dividerColor ??
        (isDark ? AppColors.composerDividerDark : AppColors.composerDividerLight);
    final effectiveInputFillColor = inputFillColor ??
        (isDark ? AppColors.composerInputDark : AppColors.composerInputLight);
    final effectiveInputTextColor = inputTextColor ??
        (isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight);
    final effectiveHintColor = hintColor ??
        (isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight);
    final effectiveIconColor = iconColor ??
        (isDark ? AppColors.iconNeutralDark : AppColors.iconNeutralLight);
    final effectiveEnabledSendColor = enabledSendColor ??
        (isDark ? AppColors.messageOutgoingDark : AppColors.messageOutgoingLight);
    final effectiveEnabledSendIconColor = enabledSendIconColor ?? Colors.white;
    final effectiveDisabledSendColor = disabledSendColor ??
        (isDark ? AppColors.disabledControlDark : AppColors.disabledControlLight);
    final effectiveDisabledSendIconColor = disabledSendIconColor ??
        (isDark ? AppColors.disabledControlTextDark : AppColors.disabledControlTextLight);

    return Container(
      key: composerKey,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: decorate
          ? BoxDecoration(
              color: effectiveShellColor,
              border: Border(
                top: BorderSide(
                  color: effectiveDividerColor,
                  width: 1.0,
                ),
              ),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            key: leadingKey,
            width: 44,
            height: 44,
            child: Center(
              child: IconButton(
                tooltip: leadingTooltip,
                onPressed: onLeadingPressed,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 44,
                  minHeight: 44,
                ),
                icon: leadingLoading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: effectiveEnabledSendColor,
                        ),
                      )
                    : Icon(
                        leadingIcon,
                        size: 24,
                        color: effectiveIconColor,
                      ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Focus(
              onKeyEvent: onKeyEvent,
              child: Container(
                key: inputContainerKey,
                constraints: const BoxConstraints(minHeight: 44),
                child: TextField(
                  key: inputKey,
                  controller: textController,
                  focusNode: focusNode,
                  onTap: onInputTap,
                  enabled: fieldEnabled,
                  readOnly: readOnly,
                  style: TextStyle(color: effectiveInputTextColor),
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: hintText,
                    isDense: true,
                    filled: true,
                    fillColor: effectiveInputFillColor,
                    hintStyle: TextStyle(
                      color: effectiveHintColor,
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 40,
                      maxWidth: 44,
                      minHeight: 44,
                      maxHeight: 44,
                    ),
                    suffixIcon: SizedBox(
                      key: emojiKey,
                      width: 40,
                      height: 44,
                      child: IconButton(
                        tooltip: emojiPanelVisible ? '打开键盘' : '选择表情',
                        onPressed: onEmojiPressed,
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          emojiPanelVisible
                              ? Icons.keyboard_alt_outlined
                              : Icons.sentiment_satisfied_alt_outlined,
                          size: 21,
                          color: effectiveIconColor,
                        ),
                      ),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: textController,
            builder: (context, value, _) {
              final sendEnabled = !sending && canSend(value);
              final reduceMotion =
                  MediaQuery.maybeOf(context)?.disableAnimations ?? false;
              return SizedBox(
                key: sendContainerKey,
                width: 44,
                height: 44,
                child: Center(
                  child: AnimatedScale(
                    scale: sendEnabled ? 1.0 : 0.94,
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 140),
                    curve: Curves.easeOutCubic,
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: IconButton.filled(
                        key: sendKey,
                        tooltip: sendTooltip,
                        onPressed: sendEnabled ? onSend : null,
                        padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(
                          fixedSize: const Size(40, 40),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: sendEnabled
                              ? effectiveEnabledSendColor
                              : effectiveDisabledSendColor,
                          foregroundColor: sendEnabled
                              ? effectiveEnabledSendIconColor
                              : effectiveDisabledSendIconColor,
                          disabledBackgroundColor: effectiveDisabledSendColor,
                          disabledForegroundColor: effectiveDisabledSendIconColor,
                        ),
                        icon: sending
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: effectiveEnabledSendIconColor,
                                ),
                              )
                            : const Icon(
                                Icons.send_rounded,
                                size: 20,
                              ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
