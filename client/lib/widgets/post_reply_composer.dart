import 'package:flutter/material.dart';

import '../controllers/post_reply_composer_controller.dart';
import '../utils/text_editing_helper.dart';
import 'emoji/app_emoji_panel.dart';
import 'emoji/favorite_image_composer_preview.dart';
import 'emoji/sticker_composer_preview.dart';

typedef PostReplySubmitCallback = Future<bool> Function(PostReplyDraft draft);

class PostReplyComposer extends StatelessWidget {
  const PostReplyComposer({
    super.key,
    required this.controller,
    required this.replyCount,
    required this.likeCount,
    required this.liked,
    required this.sending,
    required this.enabled,
    required this.onToggleLike,
    required this.onSubmit,
    required this.onNeedLogin,
  });

  final PostReplyComposerController controller;
  final int replyCount;
  final int likeCount;
  final bool liked;
  final bool sending;
  final bool enabled;
  final VoidCallback onToggleLike;
  final PostReplySubmitCallback onSubmit;
  final VoidCallback onNeedLogin;

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
          child: controller.isOpen
              ? _buildExpanded(context)
              : _buildCollapsed(context),
        );
      },
    );
  }

  Widget _buildCollapsed(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _shell(
      context,
      bottomSafeArea: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                key: const ValueKey('post-reply-collapsed-input'),
                behavior: HitTestBehavior.opaque,
                onTap: _open,
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(19),
                  ),
                  child: Text(
                    enabled ? '写下你的想法...' : '登录后参与讨论',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? Colors.white30 : Colors.grey[400],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildStat(
              icon: Icons.chat_bubble_outline_rounded,
              label: '$replyCount',
              color: isDark ? Colors.white54 : const Color(0xFF60646C),
              onTap: _open,
            ),
            const SizedBox(width: 4),
            _buildStat(
              icon: liked ? Icons.thumb_up : Icons.thumb_up_outlined,
              label: '$likeCount',
              color: liked
                  ? const Color(0xFFFF6B6B)
                  : (isDark ? Colors.white54 : const Color(0xFF60646C)),
              onTap: enabled ? onToggleLike : onNeedLogin,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpanded(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
                enabled: !sending,
              ),
            if (controller.favoriteImage != null)
              FavoriteImageComposerPreview(
                favorite: controller.favoriteImage!,
                onRemove: controller.removeFavoriteImage,
                enabled: !sending,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const ValueKey('post-reply-input'),
                              controller: controller.textController,
                              focusNode: controller.focusNode,
                              enabled: !sending,
                              readOnly: sending,
                              onTap: controller.closeEmojiPanel,
                              minLines: 1,
                              maxLines: 4,
                              textAlignVertical: TextAlignVertical.center,
                              textInputAction: TextInputAction.newline,
                              decoration: InputDecoration(
                                constraints:
                                    const BoxConstraints(minHeight: 44),
                                hintText: controller.replyToName == null
                                    ? '写下你的想法...'
                                    : '回复 @${controller.replyToName}',
                                hintStyle: TextStyle(
                                  color: isDark
                                      ? Colors.white30
                                      : Colors.grey[400],
                                  fontSize: 14,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.fromLTRB(
                                  14,
                                  13,
                                  4,
                                  9,
                                ),
                              ),
                              style: TextStyle(
                                fontSize: 14,
                                height: 1.3,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF22242A),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 42,
                            height: 44,
                            child: IconButton(
                              key: const ValueKey(
                                'post-reply-emoji-button',
                              ),
                              tooltip:
                                  controller.showEmojiPanel ? '打开键盘' : '选择表情',
                              onPressed:
                                  sending ? null : controller.toggleEmojiPanel,
                              padding: EdgeInsets.zero,
                              icon: Icon(
                                controller.showEmojiPanel
                                    ? Icons.keyboard_alt_outlined
                                    : Icons.sentiment_satisfied_alt_outlined,
                                size: 22,
                                color: isDark
                                    ? Colors.white60
                                    : const Color(0xFF60646C),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller.textController,
                    builder: (context, value, _) {
                      final canSend = !sending && !controller.draft.isEmpty;
                      return IconButton.filled(
                        key: const ValueKey('post-reply-send-button'),
                        tooltip: '发送评论',
                        onPressed: canSend ? _submit : null,
                        style: IconButton.styleFrom(
                          fixedSize: const Size(44, 44),
                          backgroundColor: isDark
                              ? const Color(0xFF82A0FF)
                              : const Color(0xFF6B8EFF),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: isDark
                              ? Colors.white.withValues(alpha: 0.10)
                              : const Color(0xFFE5E7EB),
                          disabledForegroundColor:
                              isDark ? Colors.white30 : const Color(0xFF9CA3AF),
                        ),
                        icon: sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.send_rounded, size: 20),
                      );
                    },
                  ),
                ],
              ),
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
                        onBackspace: () => deletePreviousCharacter(
                          controller.textController,
                        ),
                        enabled: !sending,
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131720) : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFEDEDED),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(top: false, bottom: bottomSafeArea, child: child),
    );
  }

  Widget _buildStat({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: SizedBox(
        width: 38,
        height: 38,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 21, color: color),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, height: 1, color: color),
            ),
          ],
        ),
      ),
    );
  }

  void _open() {
    if (!enabled) {
      onNeedLogin();
      return;
    }
    controller.open();
  }

  Future<void> _submit() async {
    final sent = await onSubmit(controller.draft);
    if (sent) controller.close(clearDraft: true);
  }
}
