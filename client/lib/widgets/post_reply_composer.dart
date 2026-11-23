import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../controllers/post_reply_composer_controller.dart';
import '../models/reply.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_spacing.dart';
import '../utils/app_feedback.dart';
import '../utils/text_editing_helper.dart';
import 'app_composer_bar.dart';
import 'app_card.dart';
import 'cached_avatar.dart';
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
    this.preserveReplyTargetOnSuccess = false,
    this.emojiPanelFallbackHeight,
    this.emojiPanelMaxHeight,
    this.embedded = false,
    this.mentionReplies = const [],
  });

  final PostReplyComposerController controller;
  final bool sending;
  final bool enabled;
  final PostReplySubmitCallback onSubmit;
  final VoidCallback onNeedLogin;
  final PostReplyImagePicker? pickImage;
  final bool preserveReplyTargetOnSuccess;
  final double? emojiPanelFallbackHeight;
  final double? emojiPanelMaxHeight;
  /// 弹层已有统一材质时，输入栏沿用父表面，避免叠加两次不透明度。
  final bool embedded;

  /// 已加载的评论：输入 `@` 时优先推荐这些作者，再补全站用户搜索结果。
  final List<Reply> mentionReplies;

  @override
  State<PostReplyComposer> createState() => _PostReplyComposerState();
}

class _PostReplyComposerState extends State<PostReplyComposer>
    with WidgetsBindingObserver {
  bool _pickingImage = false;
  Timer? _mentionSearchTimer;
  String _pendingMentionQuery = '';
  List<ReplyMentionUser> _searchedMentionUsers = const [];

  PostReplyComposerController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.textController.addListener(_scheduleMentionSearch);
  }

  @override
  void didUpdateWidget(covariant PostReplyComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.textController
          .removeListener(_scheduleMentionSearch);
      widget.controller.textController.addListener(_scheduleMentionSearch);
    }
  }

  @override
  void dispose() {
    _mentionSearchTimer?.cancel();
    controller.textController.removeListener(_scheduleMentionSearch);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final ownsInput = controller.focusNode.hasFocus ||
        controller.showEmojiPanel ||
        controller.inputHandoffActive ||
        controller.isOpen ||
        controller.keyboardInset > 0;
    if (!ownsInput) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
      controller.updateKeyboardMetrics(keyboardInset);
    });
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

  Widget _buildComposer(
    BuildContext context,
    bool isEmoji,
    double keyboardInset,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return _shell(
      context,
      isDark: isDark,
      bottomSafeArea: !isEmoji && keyboardInset == 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (controller.parentReplyId != null)
            Padding(
              key: const ValueKey('post-reply-target-banner'),
              padding: const EdgeInsets.only(left: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '回复 @${controller.replyToName?.trim().isNotEmpty == true ? controller.replyToName!.trim() : '同学'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('post-reply-clear-target'),
                    tooltip: '取消回复对象，改为评论帖子',
                    visualDensity: VisualDensity.standard,
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    onPressed:
                        widget.sending ? null : controller.clearReplyTarget,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
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
          _buildMentionSuggestions(),
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
            inputFormatters: controller.inputFormatters,
            hintText: !widget.enabled
                ? '登录后参与讨论'
                : (controller.parentReplyId == null ? '写下你的想法...' : '写下回复...'),
            leadingTooltip: controller.localImage == null ? '添加图片' : '更换图片',
            onLeadingPressed:
                widget.sending || _pickingImage ? null : _pickImage,
            leadingLoading: _pickingImage,
            emojiPanelVisible: isEmoji,
            onEmojiPressed: widget.sending ? null : _toggleEmojiPanel,
            canSend: (_) =>
                widget.enabled && !widget.sending && !controller.draft.isEmpty,
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
            hintColor:
                isDark ? AppColors.iconMutedDark : AppColors.iconMutedLight,
            enabledSendColor: AppColors.brandPrimary,
            decorate: false,
          ),
          Builder(builder: (context) {
            final reduceMotion = MediaQuery.disableAnimationsOf(context);
            final baseEmojiHeight = controller.hasObservedKeyboardHeight
                ? controller.stableKeyboardHeight
                : (widget.emojiPanelFallbackHeight ??
                    controller.stableKeyboardHeight);
            final emojiHeight = widget.emojiPanelMaxHeight != null
                ? baseEmojiHeight.clamp(0.0, widget.emojiPanelMaxHeight!)
                : baseEmojiHeight;

            final isKeyboardTakeover = !isEmoji &&
                (keyboardInset > 0 ||
                    controller.bottomPanel == PostReplyBottomPanel.keyboard);
            final duration = (reduceMotion || isKeyboardTakeover)
                ? Duration.zero
                : AppMotion.fast;

            return AnimatedContainer(
              key: const ValueKey('post-reply-emoji-panel-container'),
              duration: duration,
              curve: Curves.easeOutCubic,
              height: isEmoji ? emojiHeight : 0,
              clipBehavior: Clip.hardEdge,
              decoration: const BoxDecoration(),
              child: Offstage(
                offstage: !isEmoji,
                child: IgnorePointer(
                  ignoring: !isEmoji,
                  child: SafeArea(
                    top: false,
                    child: AppEmojiPanel(
                      key: const ValueKey('post-reply-emoji-panel'),
                      embedded: true,
                      onEmojiSelected: (emoji) =>
                          insertAtSelection(controller.textController, emoji),
                      onStickerSelected: controller.selectSticker,
                      onPackAssetSelected: (path, asset) => controller
                          .selectLocalImage(XFile(path), emojiAsset: asset),
                      onFavoriteImageSelected: controller.selectFavoriteImage,
                      onAddImage: widget.pickImage != null ? _pickImage : null,
                      favoriteImageHeaders: _favoriteImageHeaders(context),
                      onBackspace: controller.deleteBackward,
                      enabled: widget.enabled && !widget.sending,
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  /// `@` 后的关键字稳定 250ms 再搜全站用户；拼音输入未上屏时不搜。
  void _scheduleMentionSearch() {
    final value = controller.textController.value;
    final query = controller.activeMention?.query ?? '';
    if (query == _pendingMentionQuery ||
        (value.composing.isValid && !value.composing.isCollapsed)) {
      return;
    }
    _pendingMentionQuery = query;
    _mentionSearchTimer?.cancel();
    if (query.isEmpty) return;
    _mentionSearchTimer = Timer(
      const Duration(milliseconds: 250),
      () => _searchMentionUsers(query),
    );
  }

  Future<void> _searchMentionUsers(String query) async {
    final dio = context.read<AuthProvider?>()?.dio;
    if (dio == null) return;
    try {
      final response = await dio.get(
        '/search',
        queryParameters: {
          'q': query,
          'type': 'users',
          'limit': replyMentionLimit,
        },
      );
      if (!mounted || query != _pendingMentionQuery) return;
      final items = (response.data['items'] as List?) ?? const [];
      setState(() {
        _searchedMentionUsers = [
          for (final item in items)
            ReplyMentionUser.fromJson(Map<String, dynamic>.from(item as Map)),
        ];
      });
    } on DioException catch (error) {
      // 搜索失败只影响候选补全，仍可从本帖评论者中选择。
      debugPrint('搜索 @ 用户失败: $error');
    }
  }

  Widget _buildMentionSuggestions() {
    return ListenableBuilder(
      listenable: Listenable.merge(
        [controller.textController, controller.focusNode],
      ),
      builder: (context, _) {
        final mention = controller.activeMention;
        if (mention == null ||
            !controller.focusNode.hasFocus ||
            !widget.enabled ||
            widget.sending) {
          return const SizedBox.shrink();
        }
        final candidates = replyMentionCandidates(
          widget.mentionReplies,
          query: mention.query,
          searched: _searchedMentionUsers,
          viewerId: context.read<AuthProvider?>()?.user?.id,
        );
        if (candidates.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        // 归入输入框的点击区域，点选候选时不让输入框失焦收起键盘。
        return TextFieldTapRegion(
          child: Column(
            key: const ValueKey('post-reply-mention-list'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final user in candidates)
                InkWell(
                  key: ValueKey('post-reply-mention-${user.id}'),
                  onTap: () => controller.applyMention(user),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        CachedAvatar(
                          radius: 14,
                          imageUrl: user.avatar.isNotEmpty
                              ? ApiConstants.fullUrl(user.avatar)
                              : null,
                          fallbackText: user.nickname,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            user.nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _shell(
    BuildContext context, {
    required bool isDark,
    required bool bottomSafeArea,
    required Widget child,
  }) {
    return AppCardSurface(
      themeArt: false,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.zero,
        color: widget.embedded ? Colors.transparent : isDark
            ? AppColors.composerSurfaceDark
            : AppColors.composerSurfaceLight,
        border: Border(
          top: BorderSide(
            color: widget.embedded && context.watch<ThemeProvider?>()?.frostedGlass == true
                ? Colors.transparent : isDark
                ? AppColors.composerDividerDark
                : AppColors.composerDividerLight,
            width: 1.0,
          ),
        ),
      ),
      blur: widget.embedded ? 0 : 10,
      // 固定输入区父子结构，避免键盘高度变化时重建编辑器。
      child: SafeArea(
        top: false,
        left: bottomSafeArea,
        right: bottomSafeArea,
        bottom: bottomSafeArea,
        child: child,
      ),
    );
  }

  void _activateInput() {
    debugPrint('[COMMENT_IME] inputTap');
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
    final view = View.of(context);
    final keyboardInset = view.viewInsets.bottom / view.devicePixelRatio;
    controller.toggleEmojiPanel(keyboardInset: keyboardInset);
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
    if (!mounted || !sent) return;
    final latest = controller.draft;
    // 发送过程中仍可能从评论列表切换目标，成功回包只能清理已发送的草稿。
    if (latest.text == draft.text &&
        latest.parentReplyId == draft.parentReplyId &&
        latest.replyToUserId == draft.replyToUserId &&
        latest.replyToReplyId == draft.replyToReplyId &&
        identical(latest.sticker, draft.sticker) &&
        identical(latest.favoriteImage, draft.favoriteImage) &&
        identical(latest.localImage, draft.localImage)) {
      controller.close(
        clearDraft: true,
        preserveReplyTarget: widget.preserveReplyTargetOnSuccess,
        reason: 'send',
      );
    }
  }

  Map<String, String> _favoriteImageHeaders(BuildContext context) {
    final token = context.read<AuthProvider?>()?.token?.trim();
    if (token == null || token.isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer $token'};
  }
}
