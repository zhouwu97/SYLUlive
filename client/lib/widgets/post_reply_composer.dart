import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../controllers/post_reply_composer_controller.dart';
import '../providers/auth_provider.dart';
import '../theme/app_colors.dart';
import '../utils/app_feedback.dart';
import '../utils/text_editing_helper.dart';
import 'app_composer_bar.dart';
import 'emoji/app_emoji_panel.dart';
import 'emoji/favorite_image_composer_preview.dart';
import 'emoji/local_image_composer_preview.dart';
import 'emoji/sticker_composer_preview.dart';

typedef PostReplySubmitCallback = Future<bool> Function(PostReplyDraft draft);
typedef PostReplyImagePicker = Future<XFile?> Function();

class PostReplyComposer extends StatefulWidget {
  const PostReplyComposer({
    super.key,
    required this.controller,
    required this.sending,
    required this.enabled,
    required this.onSubmit,
    required this.onNeedLogin,
    this.pickImage,
  });

  final PostReplyComposerController controller;
  final bool sending;
  final bool enabled;
  final PostReplySubmitCallback onSubmit;
  final VoidCallback onNeedLogin;
  final PostReplyImagePicker? pickImage;

  @override
  State<PostReplyComposer> createState() => _PostReplyComposerState();
}

class _PostReplyComposerState extends State<PostReplyComposer>
    with WidgetsBindingObserver {
  bool _pickingImage = false;

  PostReplyComposerController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboardInset > 0) {
      controller.updateKeyboardMetrics(keyboardInset);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final isEmoji = controller.bottomPanel == PostReplyBottomPanel.emoji;
        return PopScope(
          canPop: !isEmoji,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && isEmoji) {
              controller.closeEmojiPanel();
            }
          },
          child: _buildComposer(context, isEmoji, keyboardInset),
        );
      },
    );
  }

  Widget _buildReplyTargetBanner(BuildContext context, bool isDark) {
    final name = controller.replyToName;
    if (name == null || name.isEmpty) return const SizedBox.shrink();

    return Container(
      key: const ValueKey('post-reply-target-banner'),
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.surfacePrimaryDark
            : AppColors.surfacePrimaryLight,
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? AppColors.composerDividerDark
                : AppColors.composerDividerLight,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.reply_rounded,
            size: 16,
            color: isDark
                ? AppColors.messageOutgoingDark
                : AppColors.messageOutgoingLight,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '回复 $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimaryLight,
              ),
            ),
          ),
          SizedBox(
            width: 36,
            height: 28,
            child: IconButton(
              key: const ValueKey('post-reply-cancel-target-button'),
              tooltip: '取消回复',
              padding: EdgeInsets.zero,
              onPressed: controller.clearReplyTarget,
              icon: Icon(
                Icons.close_rounded,
                size: 18,
                color: isDark
                    ? AppColors.iconNeutralDark
                    : AppColors.iconNeutralLight,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(
    BuildContext context,
    bool isEmoji,
    double keyboardInset,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final panelHeight = controller.stableKeyboardHeight;

    return _shell(
      context,
      isDark: isDark,
      bottomSafeArea: !isEmoji && keyboardInset == 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildReplyTargetBanner(context, isDark),
          if (controller.sticker != null)
            StickerComposerPreview(
              sticker: controller.sticker!,
              onRemove: controller.removeSticker,
              enabled: !widget.sending,
            ),
          if (controller.favoriteImage != null)
            FavoriteImageComposerPreview(
              favorite: controller.favoriteImage!,
              onRemove: controller.removeFavoriteImage,
              httpHeaders: _favoriteImageHeaders(context),
              enabled: !widget.sending,
            ),
          if (controller.localImage != null)
            LocalImageComposerPreview(
              image: controller.localImage!,
              onRemove: controller.removeLocalImage,
              enabled: !widget.sending,
            ),
          AppComposerBar(
            composerKey: const ValueKey('post-reply-composer'),
            leadingKey: const ValueKey('post-reply-image-button'),
            inputContainerKey: const ValueKey('post-reply-input-container'),
            inputKey: const ValueKey('post-reply-input'),
            emojiKey: const ValueKey('post-reply-emoji-button'),
            sendContainerKey:
                const ValueKey('post-reply-send-button-container'),
            sendKey: const ValueKey('post-reply-send-button'),
            textController: controller.textController,
            focusNode: controller.focusNode,
            hintText: !widget.enabled
                ? '登录后参与讨论'
                : controller.replyToName == null
                    ? '写下你的想法...'
                    : '写下回复...',
            leadingTooltip: controller.localImage == null ? '添加图片' : '更换图片',
            onLeadingPressed:
                widget.sending || _pickingImage ? null : _pickImage,
            leadingLoading: _pickingImage,
            emojiPanelVisible: isEmoji,
            onEmojiPressed: widget.sending ? null : _toggleEmojiPanel,
            canSend: (_) =>
                widget.enabled &&
                !widget.sending &&
                !controller.draft.isEmpty,
            onSend: _submit,
            sendTooltip: '发送评论',
            onInputTap: _activateInput,
            fieldEnabled: !widget.sending,
            readOnly: widget.sending || !widget.enabled,
            sending: widget.sending,
            inputFillColor: !widget.enabled
                ? (isDark
                    ? AppColors.disabledControlDark
                    : AppColors.disabledControlLight)
                : (isDark
                    ? AppColors.composerInputDark
                    : AppColors.composerInputLight),
            inputTextColor: widget.enabled
                ? (isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimaryLight)
                : (isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondaryLight),
            hintColor: isDark
                ? AppColors.iconMutedDark
                : AppColors.iconMutedLight,
            decorate: false,
          ),
          SizedBox(
            height: isEmoji ? panelHeight : 0,
            child: isEmoji
                ? AppEmojiPanel(
                    key: const ValueKey('post-reply-emoji-panel'),
                    onEmojiSelected: (emoji) =>
                        insertAtSelection(controller.textController, emoji),
                    onStickerSelected: controller.selectSticker,
                    onFavoriteImageSelected: controller.selectFavoriteImage,
                    favoriteImageHeaders: _favoriteImageHeaders(context),
                    onBackspace: () => deletePreviousCharacter(
                      controller.textController,
                    ),
                    enabled: widget.enabled && !widget.sending,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _shell(
    BuildContext context, {
    required bool isDark,
    required bool bottomSafeArea,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.composerSurfaceDark
            : AppColors.composerSurfaceLight,
        border: Border(
          top: BorderSide(
            color: isDark
                ? AppColors.composerDividerDark
                : AppColors.composerDividerLight,
            width: 1.0,
          ),
        ),
      ),
      child: SafeArea(top: false, bottom: bottomSafeArea, child: child),
    );
  }

  void _activateInput() {
    if (!widget.enabled) {
      controller.focusNode.unfocus();
      widget.onNeedLogin();
      return;
    }
    controller.open();
  }

  void _toggleEmojiPanel() {
    if (!widget.enabled) {
      widget.onNeedLogin();
      return;
    }
    controller.toggleEmojiPanel();
  }

  Future<void> _pickImage() async {
    if (!widget.enabled) {
      widget.onNeedLogin();
      return;
    }
    if (_pickingImage || widget.sending) return;
    setState(() => _pickingImage = true);
    try {
      final image = await (widget.pickImage?.call() ??
          ImagePicker().pickImage(
            source: ImageSource.gallery,
            imageQuality: 88,
            maxWidth: 2048,
          ));
      if (image != null && mounted) controller.selectLocalImage(image);
    } catch (error) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '选择图片失败', isError: true);
      debugPrint('选择评论图片失败: $error');
    } finally {
      if (mounted) setState(() => _pickingImage = false);
    }
  }

  Future<void> _submit() async {
    if (!widget.enabled) {
      widget.onNeedLogin();
      return;
    }
    final draft = controller.draft;
    final sent = await widget.onSubmit(draft);
    if (sent) controller.close(clearDraft: true);
  }

  Map<String, String> _favoriteImageHeaders(BuildContext context) {
    final token = context.read<AuthProvider?>()?.token?.trim();
    if (token == null || token.isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer $token'};
  }
}
