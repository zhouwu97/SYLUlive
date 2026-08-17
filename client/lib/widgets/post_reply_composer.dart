import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../controllers/post_reply_composer_controller.dart';
import '../providers/auth_provider.dart';
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

class _PostReplyComposerState extends State<PostReplyComposer> {
  bool _pickingImage = false;

  PostReplyComposerController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return PopScope(
          canPop: !controller.showEmojiPanel,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) controller.closeEmojiPanel();
          },
          child: _buildComposer(context),
        );
      },
    );
  }

  Widget _buildComposer(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bottomPadding = controller.showEmojiPanel
        ? 0.0
        : MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: bottomPadding),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: _shell(
        context,
        bottomSafeArea: bottomPadding == 0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                      : '回复 @${controller.replyToName}',
              leadingTooltip: controller.localImage == null ? '添加图片' : '更换图片',
              onLeadingPressed:
                  widget.sending || _pickingImage ? null : _pickImage,
              leadingLoading: _pickingImage,
              emojiPanelVisible: controller.showEmojiPanel,
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
              inputFillColor: widget.enabled
                  ? colors.surfaceContainerHighest
                  : colors.surfaceContainerHigh,
              inputTextColor:
                  widget.enabled ? colors.onSurface : colors.onSurfaceVariant,
              hintColor: colors.onSurfaceVariant.withValues(
                alpha: widget.enabled ? 1 : 0.7,
              ),
              decorate: false,
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: controller.showEmojiPanel
                  ? SizedBox(
                      height: (MediaQuery.sizeOf(context).height * 0.34)
                          .clamp(228.0, 300.0)
                          .toDouble(),
                      child: AppEmojiPanel(
                        onEmojiSelected: (emoji) =>
                            insertAtSelection(controller.textController, emoji),
                        onStickerSelected: controller.selectSticker,
                        onFavoriteImageSelected: controller.selectFavoriteImage,
                        favoriteImageHeaders: _favoriteImageHeaders(context),
                        onBackspace: () => deletePreviousCharacter(
                          controller.textController,
                        ),
                        enabled: widget.enabled && !widget.sending,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shell(
    BuildContext context, {
    required bool bottomSafeArea,
    required Widget child,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
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
    final sent = await widget.onSubmit(controller.draft);
    if (sent) controller.close(clearDraft: true);
  }

  Map<String, String> _favoriteImageHeaders(BuildContext context) {
    final token = context.read<AuthProvider?>()?.token?.trim();
    if (token == null || token.isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer $token'};
  }
}
