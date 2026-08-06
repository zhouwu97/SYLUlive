import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../models/conversation.dart';
import '../models/message_send_state.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import '../providers/theme_provider.dart';
import '../services/diagnostic_log_service.dart';
import '../services/emoji_favorite_service.dart';
import '../services/root_page_state_service.dart';
import '../utils/app_feedback.dart';
import '../utils/app_navigation.dart';
import '../utils/app_navigator.dart';
import '../utils/app_time.dart';
import '../utils/text_editing_helper.dart';
import '../theme/AppTheme.dart';
import '../widgets/cached_avatar.dart';
import '../widgets/emoji/app_emoji_panel.dart';
import '../widgets/emoji/sticker_catalog.dart';
import '../widgets/emoji/sticker_composer_preview.dart';
import '../widgets/swipe_to_exit.dart';
import 'image_viewer_screen.dart';

/// 聊天底部只有一个可见区域，避免键盘和表情面板分别驱动布局。
enum ChatBottomPanel { none, keyboard, emoji }

class ChatDetailScreen extends StatefulWidget {
  final int? conversationId;
  final User targetUser;
  final bool embedded;
  final int? initialMessageId;

  const ChatDetailScreen({
    super.key,
    this.conversationId,
    required this.targetUser,
    this.embedded = false,
    this.initialMessageId,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

class _ChatDetailScreenState extends State<ChatDetailScreen>
    with WidgetsBindingObserver, RouteAware {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _refreshTimer;
  int? _conversationId;
  int? _initialMessageId;
  bool _loadingOlder = false;
  bool _initialPositionSettled = false;
  bool _initialLoadFinished = false;
  int _positionRequestVersion = 0;
  int? _syncedPlatformConversationId;
  double _lastKeyboardInset = 0;
  double _lastKeyboardHeight = _fallbackKeyboardHeight;
  double _stableKeyboardHeight = _fallbackKeyboardHeight;
  Timer? _keyboardMetricsTimer;
  bool _hasObservedKeyboardHeight = false;
  bool _keyboardRequestPending = false;
  ChatBottomPanel _bottomPanel = ChatBottomPanel.none;
  AppSticker? _selectedSticker;
  bool _isPickingImage = false;
  bool _isSendingMedia = false;
  bool _firstContactSendPending = false;
  DateTime _lastMessageActivity = DateTime.now();
  final Map<int, GlobalKey> _messageKeys = {};
  MessageSendState? _sendState;
  MessageProvider? _messageProvider;
  PageRoute<dynamic>? _subscribedRoute;
  bool _isRouteVisible = false;
  AppLifecycleState _lifecycleState =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  int? _lastObservedServerMessageId;
  int _newMessageCount = 0;
  static const MethodChannel _privateMessageNotificationsChannel =
      MethodChannel('shenliyuan/private_message_notifications');
  static const double _fallbackKeyboardHeight = 300;
  static const double _chatHeaderHeight = 64;

  @override
  void initState() {
    super.initState();
    _conversationId = widget.conversationId;
    _initialMessageId = widget.initialMessageId;
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _textController.addListener(_saveDraft);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = context.read<MessageProvider>();
    if (!identical(provider, _messageProvider)) {
      _messageProvider?.removeListener(_handleProviderMessagesChanged);
      _messageProvider = provider..addListener(_handleProviderMessagesChanged);
    }

    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && !identical(route, _subscribedRoute)) {
      if (_subscribedRoute != null) {
        appRouteObserver.unsubscribe(this);
      }
      _subscribedRoute = route;
      appRouteObserver.subscribe(this, route);
    }
  }

  Future<void> _initialize() async {
    if (!mounted) return;
    final provider = context.read<MessageProvider>();
    _initialPositionSettled = false;
    _initialLoadFinished = false;
    final draft = provider.draftFor(widget.targetUser.id);
    _selectedSticker = appStickerById(
      provider.draftStickerFor(widget.targetUser.id),
    );
    if (draft.isNotEmpty && _textController.text.isEmpty) {
      _textController.text = draft;
      _textController.selection = TextSelection.collapsed(offset: draft.length);
    }
    try {
      if (_conversationId == null) {
        final currentUserId = context.read<AuthProvider>().user?.id;
        if (currentUserId == null) {
          provider.prepareNewConversation();
        } else {
          final conversationId = await provider.openConversationWithUser(
            currentUserId: currentUserId,
            targetUserId: widget.targetUser.id,
          );
          if (!mounted) return;
          _conversationId = conversationId;
          if (conversationId != null) {
            await _settleInitialMessagePosition();
          }
        }
      } else {
        await provider.loadMessages(
          _conversationId!,
          preferCache: true,
          aroundMessageId: _initialMessageId,
        );
        if (!mounted) return;
        final initialMessageId = _initialMessageId;
        if (initialMessageId != null &&
            !provider.containsMessage(initialMessageId)) {
          await provider.refreshLatestMessages();
          if (!mounted) return;
        }
        await _settleInitialMessagePosition();
      }
    } catch (error, stackTrace) {
      debugPrint('初始化聊天页面失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (mounted) {
        setState(() {
          _initialLoadFinished = true;
          _initialPositionSettled = true;
          _lastObservedServerMessageId =
              _latestServerMessageId(provider.messages);
        });
      }
    }
    unawaited(_refreshSendState());
    _activateConversationIfVisible();
    unawaited(_markVisibleMessagesRead());
  }

  @override
  void didUpdateWidget(covariant ChatDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedConversation =
        oldWidget.conversationId != widget.conversationId ||
            oldWidget.targetUser.id != widget.targetUser.id;
    if (changedConversation ||
        oldWidget.initialMessageId != widget.initialMessageId) {
      _deactivateConversation();
      _conversationId = widget.conversationId;
      _initialMessageId = widget.initialMessageId;
      _initialPositionSettled = false;
      _initialLoadFinished = false;
      _selectedSticker = appStickerById(
        context.read<MessageProvider>().draftStickerFor(widget.targetUser.id),
      );
      _bottomPanel = ChatBottomPanel.none;
      _keyboardRequestPending = false;
      _firstContactSendPending = false;
      _positionRequestVersion++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_subscribedRoute != null) {
      appRouteObserver.unsubscribe(this);
    }
    _messageProvider?.removeListener(_handleProviderMessagesChanged);
    _positionRequestVersion++;
    _deactivateConversation();
    _refreshTimer?.cancel();
    _keyboardMetricsTimer?.cancel();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _inputFocusNode.dispose();
    _textController.removeListener(_saveDraft);
    _textController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _activateConversationIfVisible();
      unawaited(_refreshMessages());
    } else {
      _deactivateConversation();
    }
  }

  @override
  void didPush() {
    _isRouteVisible = true;
    _activateConversationIfVisible();
  }

  @override
  void didPopNext() {
    _isRouteVisible = true;
    unawaited(_restoreConversationAfterRouteReturn());
  }

  @override
  void didPushNext() {
    _isRouteVisible = false;
    _deactivateConversation();
  }

  @override
  void didPop() {
    _isRouteVisible = false;
    _deactivateConversation();
    unawaited(_clearRestorableConversation());
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

      if (_bottomPanel == ChatBottomPanel.emoji) {
        return;
      }

      if (keyboardInset <= 0) {
        _keyboardMetricsTimer?.cancel();
        if (_bottomPanel == ChatBottomPanel.keyboard &&
            !_keyboardRequestPending) {
          setState(() => _bottomPanel = ChatBottomPanel.none);
        }
        return;
      }

      if ((keyboardInset - _lastKeyboardInset).abs() >= 0.5) {
        _lastKeyboardInset = keyboardInset;
        _scheduleStableKeyboardHeight(keyboardInset);
      }
    });
  }

  void _scheduleStableKeyboardHeight(double keyboardInset) {
    if (keyboardInset <= 0) return;
    if (!_keyboardRequestPending &&
        (keyboardInset >= _stableKeyboardHeight || !_hasObservedKeyboardHeight)) {
      _keyboardMetricsTimer?.cancel();
      setState(() {
        _stableKeyboardHeight = keyboardInset;
        _lastKeyboardHeight = keyboardInset;
        _hasObservedKeyboardHeight = true;
        if (_bottomPanel != ChatBottomPanel.emoji) {
          _bottomPanel = ChatBottomPanel.keyboard;
        }
      });
      return;
    }

    _keyboardMetricsTimer?.cancel();
    _keyboardMetricsTimer = Timer(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      final settledInset = MediaQuery.viewInsetsOf(context).bottom;
      if (settledInset > 0) {
        setState(() {
          _stableKeyboardHeight = settledInset;
          _lastKeyboardHeight = settledInset;
          _hasObservedKeyboardHeight = true;
          _keyboardRequestPending = false;
          if (_bottomPanel != ChatBottomPanel.emoji) {
            _bottomPanel = ChatBottomPanel.keyboard;
          }
        });
      }
    });
  }

  void _startPolling() {
    _refreshTimer?.cancel();
    if (!_isChatActive || _conversationId == null) return;
    _refreshTimer = Timer(_pollDelay, () async {
      await _refreshMessages();
      if (mounted && _isChatActive) _startPolling();
    });
  }

  Duration get _pollDelay {
    final idle = DateTime.now().difference(_lastMessageActivity);
    if (idle < const Duration(minutes: 10)) return const Duration(seconds: 25);
    return const Duration(seconds: 45);
  }

  Future<void> _refreshMessages() async {
    if (!mounted || !_isChatActive || _conversationId == null) return;
    await context.read<MessageProvider>().refreshMessages();
  }

  Future<void> _restoreConversationAfterRouteReturn() async {
    if (!mounted || !_isChatActive) return;
    final provider = context.read<MessageProvider>();
    final targetUserId = widget.targetUser.id;
    var conversationId = _conversationId;
    var restored = false;

    if (conversationId == null) {
      final currentUserId = context.read<AuthProvider>().user?.id;
      if (currentUserId == null) {
        provider.prepareNewConversation(targetUserId: targetUserId);
      } else {
        conversationId = await provider.openConversationWithUser(
          currentUserId: currentUserId,
          targetUserId: targetUserId,
        );
        if (!mounted ||
            !_isChatActive ||
            widget.targetUser.id != targetUserId) {
          return;
        }
        _conversationId = conversationId;
      }
      restored = true;
    } else if (provider.currentConversationId != conversationId) {
      await provider.loadMessages(conversationId, preferCache: true);
      if (!mounted ||
          !_isChatActive ||
          _conversationId != conversationId ||
          provider.currentConversationId != conversationId) {
        return;
      }
      restored = true;
    }

    _activateConversationIfVisible();
    if (!restored) unawaited(_refreshMessages());
  }

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    return _scrollController.position.pixels < 120;
  }

  void _handleScroll() {
    if (!_initialPositionSettled) return;
    if (!_scrollController.hasClients) return;
    if (_isNearBottom && _newMessageCount > 0) {
      setState(() => _newMessageCount = 0);
      unawaited(_markVisibleMessagesRead());
    }
    if (_scrollController.position.maxScrollExtent -
            _scrollController.position.pixels <=
        80) {
      _loadOlderMessages();
    }
  }

  Future<void> _loadOlderMessages() async {
    final provider = context.read<MessageProvider>();
    if (_loadingOlder || !provider.hasMore || provider.messages.isEmpty) return;

    _loadingOlder = true;
    await provider.loadOlderMessages();
    _loadingOlder = false;
  }

  bool get _isServerSendBlocked => _sendState?.isBlocked ?? false;

  bool get _isComposerBlocked =>
      _isServerSendBlocked || _firstContactSendPending;

  bool get _canStartOutgoingMessage => !_isComposerBlocked;

  void _reserveFirstContactAllowanceIfNeeded() {
    if (!(_sendState?.canUseFirstContactAllowance ?? false)) return;
    setState(() {
      // 本地先占用额度，避免首条还在 pending 时被连续发送绕过。
      _firstContactSendPending = true;
      _bottomPanel = ChatBottomPanel.none;
      _keyboardRequestPending = false;
    });
    _inputFocusNode.unfocus();
  }

  void _sendMessage() {
    final content = _textController.text.trim();
    if (!_canStartOutgoingMessage) return;
    if (content.isEmpty && _selectedSticker == null) return;
    if (content.runes.length > MessageProvider.maxMessageLength) {
      AppFeedback.showSnackBar(
        context,
        '消息内容不能超过${MessageProvider.maxMessageLength}个字符',
        isError: true,
      );
      return;
    }

    final provider = context.read<MessageProvider>();
    final stickerIdToSend = _selectedSticker?.id;
    _reserveFirstContactAllowanceIfNeeded();

    _textController.clear();
    _removeSelectedSticker();
    provider.clearDraft(widget.targetUser.id);
    final sendFuture = provider.sendMessage(
      widget.targetUser.id,
      content,
      stickerId: stickerIdToSend,
      senderId: context.read<AuthProvider>().user?.id,
    );
    _lastMessageActivity = DateTime.now();
    unawaited(_scrollToLatestMessage(settle: true));
    unawaited(_completeOutgoingSend(sendFuture));
  }

  Future<void> _pickAndSendImage() async {
    if (!_canStartOutgoingMessage || _isPickingImage || _isSendingMedia) {
      return;
    }
    setState(() => _isPickingImage = true);
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 2048,
      );
      if (image == null || !mounted) return;
      if (!_canStartOutgoingMessage) return;
      final provider = context.read<MessageProvider>();
      setState(() {
        _isPickingImage = false;
        _isSendingMedia = true;
      });
      _reserveFirstContactAllowanceIfNeeded();
      final sendFuture = provider.sendImageMessage(
        widget.targetUser.id,
        image,
        senderId: context.read<AuthProvider>().user?.id,
      );
      _lastMessageActivity = DateTime.now();
      unawaited(_scrollToLatestMessage(settle: true));
      unawaited(_completeOutgoingSend(sendFuture, isMedia: true));
    } catch (error) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '选择图片失败', isError: true);
      debugPrint('选择私信图片失败: $error');
    } finally {
      if (mounted && _isPickingImage) {
        setState(() => _isPickingImage = false);
      }
    }
  }

  void _retryMessage(Message message) {
    final clientMessageId = message.clientMessageId;
    if (clientMessageId == null) return;
    unawaited(_scrollToLatestMessage(settle: true));
    final sendFuture = context.read<MessageProvider>().retryMessage(
          widget.targetUser.id,
          clientMessageId,
        );
    unawaited(_completeOutgoingSend(sendFuture));
  }

  Future<void> _completeOutgoingSend(
    Future<Message?> sendFuture, {
    bool isMedia = false,
  }) async {
    try {
      final message = await sendFuture;
      if (!mounted) return;
      if (message != null) {
        _conversationId = message.conversationId;
        _activateConversationIfVisible();
        _startPolling();
      }
      // 成功和失败都刷新限制状态；失败只保留在对应消息气泡中。
      unawaited(_refreshSendState());
    } catch (error, stackTrace) {
      debugPrint('私信发送流程异常: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (isMedia && mounted) {
        setState(() => _isSendingMedia = false);
      }
    }
  }

  /// 拉取陌生人限制状态。失败时按"允许发送"宽松处理避免阻塞 UI。
  Future<void> _refreshSendState() async {
    if (!mounted) return;
    final provider = context.read<MessageProvider>();
    MessageSendState? next;
    try {
      next = await provider.getSendState(widget.targetUser.id);
    } catch (e) {
      debugPrint('拉取 send-state 失败: $e');
    }
    if (!mounted) return;
    setState(() {
      _sendState = next;
      if (next?.isBlocked ?? false) {
        _bottomPanel = ChatBottomPanel.none;
        _keyboardRequestPending = false;
        _inputFocusNode.unfocus();
      }
      if (next?.targetFollowsMe == true || next?.targetReplied == true) {
        _firstContactSendPending = false;
      }
    });
  }

  void _saveDraft() {
    if (!mounted) return;
    context.read<MessageProvider>().updateDraft(
          widget.targetUser.id,
          _textController.text,
        );
  }

  void _toggleEmojiPanel() {
    if (_isComposerBlocked) return;
    if (_bottomPanel == ChatBottomPanel.emoji) {
      _showKeyboard();
      return;
    }
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    setState(() {
      if (keyboardInset > 0) {
        _stableKeyboardHeight = keyboardInset;
        _lastKeyboardHeight = keyboardInset;
        _hasObservedKeyboardHeight = true;
      }
      _bottomPanel = ChatBottomPanel.emoji;
      _keyboardRequestPending = false;
    });
    _inputFocusNode.unfocus();
  }

  void _showKeyboard() {
    if (_isComposerBlocked) return;
    if (_isDesktopPlatform) {
      _inputFocusNode.requestFocus();
      return;
    }
    setState(() {
      _bottomPanel = ChatBottomPanel.keyboard;
      _keyboardRequestPending = true;
    });
    _inputFocusNode.requestFocus();
  }

  void _dismissBottomPanel() {
    _inputFocusNode.unfocus();
    if (_bottomPanel == ChatBottomPanel.none) return;
    setState(() {
      _bottomPanel = ChatBottomPanel.none;
      _keyboardRequestPending = false;
    });
  }

  void _insertEmoji(String emoji) {
    if (_isComposerBlocked) return;
    insertAtSelection(_textController, emoji);
    _saveDraft();
  }

  void _selectSticker(AppSticker sticker) {
    if (_isComposerBlocked) return;
    setState(() {
      _selectedSticker = sticker;
    });
    context.read<MessageProvider>().updateDraftSticker(
          widget.targetUser.id,
          sticker.id,
        );
  }

  void _removeSelectedSticker() {
    setState(() {
      _selectedSticker = null;
    });
    context.read<MessageProvider>().updateDraftSticker(
          widget.targetUser.id,
          null,
        );
  }

  Future<void> _sendFavoriteImage(EmojiFavoriteItem favorite) async {
    final imageUrl = favorite.imageUrl?.trim();
    if (imageUrl == null ||
        imageUrl.isEmpty ||
        !_canStartOutgoingMessage ||
        _isSendingMedia) {
      return;
    }

    setState(() => _isSendingMedia = true);
    try {
      final file = await DefaultCacheManager().getSingleFile(
        ApiConstants.fullUrl(imageUrl),
      );
      if (!mounted) return;
      if (!_canStartOutgoingMessage) return;
      final provider = context.read<MessageProvider>();
      _reserveFirstContactAllowanceIfNeeded();
      final sendFuture = provider.sendImageMessage(
        widget.targetUser.id,
        XFile(file.path),
        senderId: context.read<AuthProvider>().user?.id,
      );
      _lastMessageActivity = DateTime.now();
      unawaited(_scrollToLatestMessage(settle: true));
      await _completeOutgoingSend(sendFuture, isMedia: true);
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '收藏图片发送失败', isError: true);
      }
      debugPrint('发送收藏图片失败: $error');
    } finally {
      if (mounted && _isSendingMedia) {
        setState(() => _isSendingMedia = false);
      }
    }
  }

  double get _emojiPanelHeight {
    return _stableKeyboardHeight;
  }

  bool get _isDesktopPlatform {
    final platform = Theme.of(context).platform;
    return platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
  }

  double get _keyboardViewportHeight {
    if (_keyboardRequestPending) {
      return _stableKeyboardHeight;
    }
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return keyboardInset > 0 ? keyboardInset : _stableKeyboardHeight;
  }

  double get _bottomViewportHeight {
    switch (_bottomPanel) {
      case ChatBottomPanel.none:
        return 0;
      case ChatBottomPanel.keyboard:
        return _keyboardViewportHeight;
      case ChatBottomPanel.emoji:
        return _emojiPanelHeight;
    }
  }

  Widget _buildBottomViewport() {
    final height = _bottomViewportHeight;
    final showEmojiPanel =
        _bottomPanel == ChatBottomPanel.emoji && !_isComposerBlocked;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      key: const ValueKey('chat-bottom-viewport'),
      width: double.infinity,
      height: height,
      child: ColoredBox(
        color: isDark ? const Color(0xFF1B202A) : Colors.white,
        child: showEmojiPanel
            ? SafeArea(
                top: false,
                child: AppEmojiPanel(
                  key: const ValueKey('chat-emoji-panel'),
                  onEmojiSelected: _insertEmoji,
                  onStickerSelected: _selectSticker,
                  onFavoriteImageSelected: _sendFavoriteImage,
                  onBackspace: () => deletePreviousCharacter(_textController),
                  // 媒体上传不应冻结 Emoji 或 Sticker 的连续发送能力。
                  enabled: !_isComposerBlocked,
                ),
              )
            : const SizedBox.expand(),
      ),
    );
  }

  bool get _isChatActive =>
      _isRouteVisible && _lifecycleState == AppLifecycleState.resumed;

  void _activateConversationIfVisible() {
    final conversationId = _conversationId;
    if (!_isChatActive || conversationId == null) return;
    unawaited(_saveRestorableConversation(conversationId));
    _messageProvider?.setActiveConversation(
      conversationId,
      embedded: widget.embedded,
    );
    unawaited(_syncCurrentConversationToPlatform(conversationId));
    _startPolling();
    unawaited(_markVisibleMessagesRead());
  }

  Future<void> _saveRestorableConversation(int conversationId) async {
    final accountId = context.read<AuthProvider>().user?.id;
    if (accountId == null || accountId <= 0 || conversationId <= 0) return;
    try {
      await RootPageStateStore.instance.saveConversation(
        RestorableConversationState(
          accountId: accountId,
          conversationId: conversationId,
          targetUserId: widget.targetUser.id,
          targetNickname: widget.targetUser.nickname,
          targetAvatar: widget.targetUser.avatar,
        ),
      );
    } catch (error) {
      DiagnosticLogService.instance.record(
        level: 'warning',
        source: '存储',
        type: '私信页面状态保存失败',
        summary: '无法保存当前私信会话位置',
        detail: error.toString(),
        eventCode: 'navigation_conversation_state_save_failed',
        category: 'navigation',
        operation: 'save',
        result: 'failure',
      );
    }
  }

  Future<void> _clearRestorableConversation() async {
    try {
      await RootPageStateStore.instance.clearConversation();
    } catch (error) {
      DiagnosticLogService.instance.record(
        level: 'warning',
        source: '存储',
        type: '私信页面状态清理失败',
        summary: '无法清除已退出的私信会话位置',
        detail: error.toString(),
        eventCode: 'navigation_conversation_state_clear_failed',
        category: 'navigation',
        operation: 'clear',
        result: 'failure',
      );
    }
  }

  void _deactivateConversation() {
    _refreshTimer?.cancel();
    final provider = _messageProvider;
    if (provider?.activeConversationId == _conversationId) {
      provider?.setActiveConversation(null);
    }
    unawaited(_syncCurrentConversationToPlatform(null));
  }

  Future<void> _markVisibleMessagesRead() async {
    final conversationId = _conversationId;
    if (!_isChatActive || conversationId == null || !_isNearBottom) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_isChatActive || !_isNearBottom) return;
    final provider = context.read<MessageProvider>();
    final currentUserId = context.read<AuthProvider>().user?.id;
    if (currentUserId == null) return;
    final latestIncoming = provider.latestIncomingMessageFor(currentUserId);
    if (latestIncoming == null ||
        _messageKeys[latestIncoming.id]?.currentContext == null) {
      return;
    }
    await provider.markRead(
      conversationId,
      markedMessageId: latestIncoming.id,
    );
    if (!mounted || !_isChatActive) return;
    try {
      await _privateMessageNotificationsChannel.invokeMethod(
        'clearConversationNotifications',
        {'conversationId': conversationId},
      );
    } catch (e) {
      debugPrint('清理私信通知失败: $e');
    }
  }

  void _handleProviderMessagesChanged() {
    if (!mounted || !_initialLoadFinished) return;
    final provider = _messageProvider;
    if (provider == null) return;
    final providerConversationId = provider.currentConversationId;
    if (_isChatActive &&
        _conversationId == null &&
        providerConversationId != null) {
      _conversationId = providerConversationId;
      _activateConversationIfVisible();
    }
    if (providerConversationId != _conversationId) return;

    if (_isChatActive) {
      final focusMessageId = provider.takeMessageFocusRequest();
      if (focusMessageId != null) {
        unawaited(_focusRequestedMessage(focusMessageId));
      }
    }

    final latestId = _latestServerMessageId(provider.messages);
    final previousId = _lastObservedServerMessageId;
    if (latestId == null || latestId == previousId) return;
    final newMessages = provider.messages.where(
      (message) =>
          message.id > 0 && (previousId == null || message.id > previousId),
    );
    final currentUserId = context.read<AuthProvider>().user?.id;
    final incomingCount = newMessages
        .where((message) => message.senderId != currentUserId)
        .length;
    final includesOwnMessage =
        newMessages.any((message) => message.senderId == currentUserId);
    final wasNearBottom = _isNearBottom;
    _lastObservedServerMessageId = latestId;
    _lastMessageActivity = DateTime.now();
    if (incomingCount > 0) {
      if (_firstContactSendPending) {
        setState(() => _firstContactSendPending = false);
      }
      // 对方回复后可能解除陌生人限制，主动与服务端状态重新同步。
      unawaited(_refreshSendState());
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (includesOwnMessage || wasNearBottom) {
        if (_newMessageCount != 0) setState(() => _newMessageCount = 0);
        unawaited(_scrollToLatestMessage(settle: true));
        unawaited(_markVisibleMessagesRead());
      } else if (incomingCount > 0) {
        setState(() => _newMessageCount += incomingCount);
      }
    });
  }

  int? _latestServerMessageId(List<Message> messages) {
    int? latest;
    for (final message in messages) {
      if (message.id > 0 && (latest == null || message.id > latest)) {
        latest = message.id;
      }
    }
    return latest;
  }

  Future<void> _syncCurrentConversationToPlatform(int? conversationId) async {
    if (_syncedPlatformConversationId == conversationId) return;
    _syncedPlatformConversationId = conversationId;
    try {
      await _privateMessageNotificationsChannel.invokeMethod(
        'setCurrentConversation',
        {'conversationId': conversationId},
      );
    } catch (e) {
      debugPrint('同步当前私信会话失败: $e');
    }
  }

  GlobalKey _messageKeyFor(int messageId) {
    return _messageKeys.putIfAbsent(messageId, GlobalKey.new);
  }

  Future<void> _settleInitialMessagePosition() async {
    final targetMessageId = _initialMessageId;
    final requestVersion = ++_positionRequestVersion;
    var targetFound = false;
    for (var attempt = 0; attempt < 5; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || requestVersion != _positionRequestVersion) {
        return;
      }

      if (targetMessageId != null && _ensureMessageVisible(targetMessageId)) {
        targetFound = true;
        continue;
      }

      if (targetMessageId == null) _jumpToLatestMessage();
      await Future<void>.delayed(const Duration(milliseconds: 45));
    }

    if (!mounted || requestVersion != _positionRequestVersion) {
      return;
    }
    if (!targetFound && targetMessageId != null) {
      _jumpToLatestMessage();
    }
    _initialPositionSettled = true;
  }

  bool _ensureMessageVisible(int targetMessageId) {
    final targetContext = _messageKeys[targetMessageId]?.currentContext;
    if (targetContext == null) {
      _jumpNearMessage(targetMessageId);
      return false;
    }
    Scrollable.ensureVisible(
      targetContext,
      duration: Duration.zero,
      alignment: 0.72,
      curve: Curves.easeOut,
    );
    return true;
  }

  void _jumpNearMessage(int targetMessageId) {
    if (!_scrollController.hasClients) return;
    final messages = _messageProvider?.messages;
    if (messages == null || messages.length < 2) return;
    final messageIndex = messages.indexWhere(
      (message) => message.id == targetMessageId,
    );
    if (messageIndex < 0) return;
    final reverseIndex = messages.length - 1 - messageIndex;
    final targetOffset = _scrollController.position.maxScrollExtent *
        reverseIndex /
        (messages.length - 1);
    _scrollController.jumpTo(
      targetOffset
          .clamp(
            _scrollController.position.minScrollExtent,
            _scrollController.position.maxScrollExtent,
          )
          .toDouble(),
    );
  }

  Future<void> _focusRequestedMessage(int messageId) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_isChatActive) return;
      if (_ensureMessageVisible(messageId)) {
        if (_newMessageCount != 0) setState(() => _newMessageCount = 0);
        unawaited(_markVisibleMessagesRead());
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 45));
    }
  }

  void _jumpToLatestMessage() {
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.jumpTo(0);
  }

  Future<void> _scrollToLatestMessage({
    bool jump = false,
    bool settle = false,
  }) async {
    final attempts = settle ? 4 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scrollController.hasClients) return;
      if (jump || attempt > 0) {
        _scrollController.jumpTo(0);
      } else {
        await _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      if (settle) {
        await Future<void>.delayed(const Duration(milliseconds: 35));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageProvider>();
    final currentUser = context.watch<AuthProvider>().user;
    final currentUserId = currentUser?.id ?? 0;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final body = _buildConversationBody(provider, currentUserId, currentUser);
    if (widget.embedded) {
      return PopScope(
        canPop: _bottomPanel == ChatBottomPanel.none,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _bottomPanel != ChatBottomPanel.none) {
            _dismissBottomPanel();
          }
        },
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              _buildChatHeader(showBackButton: false),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    return SwipeToExit(
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _chatSystemOverlayStyle(isDark),
        child: PopScope(
          canPop: _bottomPanel == ChatBottomPanel.none,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && _bottomPanel != ChatBottomPanel.none) {
              _dismissBottomPanel();
            }
          },
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              automaticallyImplyLeading: false,
              toolbarHeight: _chatHeaderHeight,
              backgroundColor: _chatSurfaceColor(),
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              systemOverlayStyle: _chatSystemOverlayStyle(isDark),
              flexibleSpace: _buildChatHeader(showBackButton: true),
            ),
            body: body,
          ),
        ),
      ),
    );
  }

  Widget _buildConversationBody(
    MessageProvider provider,
    int currentUserId,
    User? currentUser,
  ) {
    final content = Column(
      children: [
        Expanded(
          child: _buildMessageArea(
            provider,
            currentUserId,
            currentUser,
            includeBackdrop: widget.embedded,
          ),
        ),
        _buildComposerArea(),
        _buildBottomViewport(),
      ],
    );

    if (widget.embedded) return content;

    return Stack(
      children: [
        Positioned.fill(child: _buildStandaloneMessageBackdrop()),
        content,
      ],
    );
  }

  Color _chatSurfaceColor() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight;
  }

  SystemUiOverlayStyle _chatSystemOverlayStyle(bool isDark) {
    return (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
        .copyWith(
      statusBarColor: _chatSurfaceColor(),
      systemNavigationBarColor: isDark ? const Color(0xFF1B202A) : Colors.white,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    );
  }

  Widget _buildChatHeader({required bool showBackButton}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : const Color(0xFF171719);
    final muted = isDark ? Colors.white60 : const Color(0xFF9A9490);
    final nickname = widget.targetUser.nickname.isEmpty
        ? '用户${widget.targetUser.id}'
        : widget.targetUser.nickname;
    return Container(
      key: const ValueKey('chat-header'),
      decoration: BoxDecoration(
        color: _chatSurfaceColor(),
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFECE8E4),
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: _chatHeaderHeight,
          child: Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: showBackButton
                    ? IconButton(
                        key: const ValueKey('chat-header-back'),
                        tooltip: '返回',
                        onPressed: () {
                          Navigator.maybePop(context);
                        },
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.arrow_back_ios_new_rounded,
                            size: 20),
                      )
                    : null,
              ),
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey('chat-header-profile'),
                    onTap: _openTargetProfile,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CachedAvatar(
                            imageUrl: widget.targetUser.avatar.isEmpty
                                ? null
                                : ApiConstants.fullUrl(
                                    widget.targetUser.avatar,
                                  ),
                            radius: 20,
                            fallbackText: nickname,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  nickname,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: foreground,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  '点击头像查看主页',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: muted,
                                    fontSize: 11,
                                    height: 1.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                height: 44,
                child: PopupMenuButton<String>(
                  key: const ValueKey('chat-header-more'),
                  tooltip: '更多',
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: foreground,
                    size: 24,
                  ),
                  onSelected: (_) => _openTargetProfile(),
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(
                      value: 'profile',
                      child: Text('查看主页'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openTargetProfile() {
    _dismissBottomPanel();
    AppNavigation.openUserHome(context, userId: widget.targetUser.id);
  }

  Widget _buildMessageArea(
    MessageProvider provider,
    int currentUserId,
    User? currentUser, {
    required bool includeBackdrop,
  }) {
    if (provider.messageLoading &&
        !_initialLoadFinished &&
        provider.messages.isEmpty) {
      return _wrapMessageBackdrop(
        const Center(child: CircularProgressIndicator()),
        includeBackdrop,
      );
    }
    if (provider.messageError != null && provider.messages.isEmpty) {
      return _wrapMessageBackdrop(
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(provider.messageError!),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _initialize,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
        includeBackdrop,
      );
    }
    if (provider.messages.isEmpty) {
      return _wrapMessageBackdrop(
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.waving_hand_outlined,
                size: 56,
                color: Colors.grey.shade500,
              ),
              const SizedBox(height: 14),
              Text(
                '向 ${widget.targetUser.nickname} 打个招呼吧',
                style: TextStyle(color: Colors.grey.shade700),
              ),
            ],
          ),
        ),
        includeBackdrop,
      );
    }

    final lastOwnMessageKey = provider.messages.reversed
        .where((message) => message.senderId == currentUserId)
        .firstOrNull
        ?.stableKey;
    final messageList = GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        _dismissBottomPanel();
      },
      child: ListView.builder(
          controller: _scrollController,
          reverse: true,
          padding: const EdgeInsets.fromLTRB(
            12,
            12,
            12,
            18,
          ),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: provider.messages.length + (provider.loadingMore ? 1 : 0),
          itemBuilder: (context, index) {
            final messageCount = provider.messages.length;
            final itemCount = messageCount + (provider.loadingMore ? 1 : 0);
            if (provider.loadingMore && index == itemCount - 1) {
              return const Padding(
                padding: EdgeInsets.all(12),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            final messageIndex = messageCount - 1 - index;
            final message = provider.messages[messageIndex];
            final previous =
                messageIndex > 0 ? provider.messages[messageIndex - 1] : null;
            final next = messageIndex < messageCount - 1
                ? provider.messages[messageIndex + 1]
                : null;
            final showTime = previous == null ||
                message.createdAt
                        .difference(previous.createdAt)
                        .inMinutes
                        .abs() >=
                    5;
            final groupedWithPrevious = previous != null &&
                previous.senderId == message.senderId &&
                !showTime;
            final groupedWithNext = next != null &&
                next.senderId == message.senderId &&
                next.createdAt.difference(message.createdAt).inMinutes.abs() <
                    5;
            return Column(
              key: _messageKeyFor(message.id),
              children: [
                if (showTime) _buildTimeLabel(message.createdAt),
                _buildMessageBubble(
                  message,
                  message.senderId == currentUserId,
                  currentUser,
                  showAvatar: !groupedWithNext,
                  isGroupStart: !groupedWithPrevious,
                  isGroupEnd: !groupedWithNext,
                  showStatus: message.isPending ||
                      message.isFailed ||
                      message.stableKey == lastOwnMessageKey,
                ),
              ],
            );
          }),
    );
    return _wrapMessageBackdrop(
      Stack(
        children: [
          Positioned.fill(child: messageList),
          if (_newMessageCount > 0)
            Positioned(
              right: 16,
              bottom: 12,
              child: FilledButton.icon(
                onPressed: () {
                  setState(() => _newMessageCount = 0);
                  unawaited(_scrollToLatestMessage(settle: true));
                  unawaited(_markVisibleMessagesRead());
                },
                icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                label: Text('$_newMessageCount 条新消息'),
              ),
            ),
        ],
      ),
      includeBackdrop,
    );
  }

  Widget _wrapMessageBackdrop(Widget child, bool includeBackdrop) {
    return includeBackdrop ? _buildMessageBackdrop(child) : child;
  }

  Widget _buildMessageBackdrop(Widget child) {
    return Stack(
      children: [
        Positioned.fill(child: _buildChatBackground()),
        child,
      ],
    );
  }

  Widget _buildStandaloneMessageBackdrop() {
    return _buildChatBackground();
  }

  Widget _buildChatBackground() {
    final themeProvider = context.watch<ThemeProvider>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgPath = themeProvider.getCustomBackgroundImageFor(context);
    if (!themeProvider.shouldShowCustomBackground ||
        bgPath == null ||
        bgPath.isEmpty) {
      return ColoredBox(
        color: isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight,
      );
    }

    final imageProvider = _chatBackgroundImageProvider(bgPath);

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildChatBackgroundImage(
          imageProvider: imageProvider,
        ),
        ColoredBox(
          color: isDark
              ? Colors.black.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.15),
        ),
      ],
    );
  }

  ImageProvider _chatBackgroundImageProvider(String bgPath) {
    if (ThemeProvider.isBundledAssetBackground(bgPath)) {
      return AssetImage(ThemeProvider.resolveBundledAssetPath(bgPath));
    }
    if (ThemeProvider.isLocalFileBackground(bgPath)) {
      return FileImage(File(bgPath));
    }
    return NetworkImage(bgPath);
  }

  Widget _buildChatBackgroundImage({
    required ImageProvider imageProvider,
  }) {
    const fallbackColor = kCleanWarmBackgroundLight;
    // 私信消息区始终铺满可视区域，避免 contain 模式在两侧留下暖白空隙。
    return Image(
      image: imageProvider,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const ColoredBox(color: fallbackColor),
    );
  }

  Widget _buildTimeLabel(DateTime time) {
    final local = AppTime.toShanghai(time);
    final now = AppTime.nowShanghai();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        DateFormat(sameDay ? 'HH:mm' : 'MM-dd HH:mm').format(local),
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xFF9A9490),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(
    Message message,
    bool isMine,
    User? currentUser, {
    required bool showAvatar,
    required bool isGroupStart,
    required bool isGroupEnd,
    required bool showStatus,
  }) {
    final imageUrl = message.imageUrl.isEmpty
        ? null
        : ApiConstants.fullUrl(message.imageUrl);
    final localImagePath = message.localImagePath?.trim();
    final hasImage = imageUrl != null || localImagePath?.isNotEmpty == true;
    final stickerUrl =
        message.hasSticker ? ApiConstants.fullUrl(message.stickerUrl) : null;
    final sender = isMine ? currentUser : (message.sender ?? widget.targetUser);
    final senderAvatar = sender?.avatar.isEmpty ?? true
        ? null
        : ApiConstants.fullUrl(sender!.avatar);
    final senderName = sender?.nickname.isNotEmpty == true
        ? sender!.nickname
        : (isMine ? '我' : widget.targetUser.nickname);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bubbleColor = isMine
        ? AppTheme.primaryColor
        : (isDark ? const Color(0xFF252B36) : Colors.white);
    final textColor = isMine
        ? Colors.white
        : (isDark ? Colors.white : const Color(0xFF111827));
    final groupGap = isGroupStart ? 10.0 : 4.0;
    final bubbleRadius = _messageBubbleRadius(
      isMine: isMine,
      isGroupStart: isGroupStart,
      isGroupEnd: isGroupEnd,
    );

    return Padding(
      padding: EdgeInsets.only(top: groupGap, bottom: isGroupEnd ? 3 : 0),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) ...[
            _buildMessageAvatarSlot(
              showAvatar: showAvatar,
              imageUrl: senderAvatar,
              fallbackText: senderName,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onLongPress: () => _showMessageActions(message, isMine),
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: (MediaQuery.sizeOf(context).width * 0.72)
                          .clamp(180.0, 420.0)
                          .toDouble(),
                    ),
                    padding: message.isStickerOnly || hasImage
                        ? const EdgeInsets.all(4)
                        : const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                    decoration: BoxDecoration(
                      color: message.isStickerOnly
                          ? Colors.transparent
                          : bubbleColor,
                      borderRadius: bubbleRadius,
                      border: Border.all(
                        color: message.isStickerOnly
                            ? Colors.transparent
                            : isMine
                                ? Colors.transparent
                                : (isDark
                                    ? Colors.white.withValues(alpha: 0.10)
                                    : const Color(0xFFECE8E4)),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (stickerUrl != null)
                          _buildStickerImage(stickerUrl, message.stickerId),
                        if (hasImage)
                          GestureDetector(
                            key: ValueKey(
                              'message-image-${message.stableKey}',
                            ),
                            onTap: imageUrl == null
                                ? null
                                : () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ImageViewerScreen(
                                          imageUrls: [imageUrl],
                                        ),
                                      ),
                                    ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: _buildMessageImage(
                                localImagePath: localImagePath,
                                imageUrl: imageUrl,
                              ),
                            ),
                          ),
                        if (message.hasTextContent)
                          Padding(
                            padding: hasImage || stickerUrl != null
                                ? const EdgeInsets.fromLTRB(8, 7, 8, 6)
                                : EdgeInsets.zero,
                            child: SelectableText(
                              message.content,
                              style: TextStyle(
                                color: textColor,
                                fontSize: 15,
                                height: 1.4,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (isMine && showStatus)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, right: 2),
                    child: _buildMessageStatus(message),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  BorderRadius _messageBubbleRadius({
    required bool isMine,
    required bool isGroupStart,
    required bool isGroupEnd,
  }) {
    const outer = Radius.circular(18);
    const grouped = Radius.circular(8);
    const tail = Radius.circular(8);
    if (isMine) {
      return BorderRadius.only(
        topLeft: outer,
        topRight: isGroupStart ? outer : grouped,
        bottomLeft: outer,
        bottomRight: isGroupEnd ? tail : grouped,
      );
    }
    return BorderRadius.only(
      topLeft: isGroupStart ? outer : grouped,
      topRight: outer,
      bottomLeft: isGroupEnd ? tail : grouped,
      bottomRight: outer,
    );
  }

  Widget _buildMessageAvatarSlot({
    required bool showAvatar,
    required String? imageUrl,
    required String fallbackText,
  }) {
    return SizedBox(
      width: 40,
      height: 40,
      child: showAvatar
          ? CachedAvatar(
              imageUrl: imageUrl,
              radius: 20,
              fallbackText: fallbackText,
            )
          : null,
    );
  }

  Widget _buildMessageImage({
    required String? localImagePath,
    required String? imageUrl,
  }) {
    Widget networkImage() {
      if (imageUrl == null) return _buildBrokenMessageImage();
      return CachedNetworkImage(
        imageUrl: imageUrl,
        width: 210,
        height: 156,
        fit: BoxFit.cover,
        placeholder: (_, __) => const SizedBox(
          width: 210,
          height: 156,
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
        errorWidget: (_, __, ___) => _buildBrokenMessageImage(),
      );
    }

    if (localImagePath?.isNotEmpty == true) {
      return Image.file(
        File(localImagePath!),
        key: ValueKey('local-message-image-$localImagePath'),
        width: 210,
        height: 156,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => networkImage(),
      );
    }
    return networkImage();
  }

  Widget _buildStickerImage(String imageUrl, String? stickerId) {
    final localSticker = appStickerById(stickerId);
    if (localSticker != null) {
      return Image.asset(
        localSticker.thumbnailAsset,
        key: ValueKey('message-sticker-asset-${localSticker.id}'),
        width: 156,
        height: 156,
        fit: BoxFit.contain,
      );
    }
    return CachedNetworkImage(
      key: ValueKey('message-sticker-$imageUrl'),
      imageUrl: imageUrl,
      width: 156,
      height: 156,
      fit: BoxFit.contain,
      placeholder: (_, __) => const SizedBox(
        width: 156,
        height: 156,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      errorWidget: (_, __, ___) => _buildBrokenStickerImage(),
    );
  }

  Widget _buildBrokenStickerImage() {
    return const SizedBox(
      width: 156,
      height: 156,
      child: Center(child: Icon(Icons.broken_image_outlined)),
    );
  }

  Widget _buildBrokenMessageImage() {
    return const SizedBox(
      width: 210,
      height: 156,
      child: Center(child: Icon(Icons.broken_image_outlined)),
    );
  }

  Widget _buildMessageStatus(Message message) {
    if (message.isPending) {
      return const Text(
        '发送中',
        key: ValueKey('message-status-pending'),
        style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
      );
    }
    if (message.isFailed) {
      return Tooltip(
        message: message.localError ?? '发送失败',
        child: InkWell(
          key: ValueKey('retry-${message.stableKey}'),
          onTap: () => _retryMessage(message),
          borderRadius: BorderRadius.circular(4),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Text(
              '发送失败 · 点击重试',
              style: TextStyle(fontSize: 11, color: Color(0xFFDC2626)),
            ),
          ),
        ),
      );
    }
    return Text(
      message.readAt == null ? '已送达' : '已读',
      key: ValueKey(
          'message-status-${message.readAt == null ? 'sent' : 'read'}'),
      style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
    );
  }

  Future<void> _showMessageActions(Message message, bool isMine) async {
    final canCopy = message.content.trim().isNotEmpty;
    final canDelete =
        isMine && message.isFailed && message.clientMessageId != null;
    final sticker = appStickerById(message.stickerId);
    final favoriteImageUrl =
        message.imageUrl.isEmpty ? null : message.imageUrl.trim();
    final canFavorite = sticker != null || favoriteImageUrl != null;
    if (!canCopy && !canDelete && !canFavorite) return;

    final favoriteService = EmojiFavoriteService.instance;
    final isFavorite = sticker != null
        ? await favoriteService.containsSticker(sticker.id)
        : favoriteImageUrl != null
            ? await favoriteService.containsImage(favoriteImageUrl)
            : false;
    if (!mounted) return;

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('复制'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
            if (canFavorite)
              ListTile(
                leading: Icon(
                  isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                ),
                title: Text(isFavorite ? '取消收藏' : '收藏'),
                onTap: () => Navigator.pop(context, 'favorite'),
              ),
            if (canDelete)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除本地失败消息'),
                textColor: Colors.red.shade700,
                iconColor: Colors.red.shade700,
                onTap: () => Navigator.pop(context, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.content));
      if (mounted) AppFeedback.showSnackBar(context, '已复制');
    } else if (action == 'delete') {
      context.read<MessageProvider>().deleteFailedMessage(
            message.clientMessageId!,
          );
    } else if (action == 'favorite') {
      final added = sticker != null
          ? await favoriteService.toggleSticker(sticker.id)
          : await favoriteService.toggleImage(favoriteImageUrl!);
      if (mounted) {
        AppFeedback.showSnackBar(
          context,
          added ? '已添加到收藏' : '已取消收藏',
        );
      }
    }
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isDesktopPlatform ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final composing = _textController.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (_canStartOutgoingMessage && _textController.text.trim().isNotEmpty) {
      _sendMessage();
    }
    return KeyEventResult.handled;
  }

  Widget _buildInputBar() {
    final blocked = _isComposerBlocked;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (blocked) _buildPMLockedBanner(),
        Container(
          key: const ValueKey('chat-composer'),
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1B202A) : Colors.white,
            border: Border(
              top: BorderSide(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06),
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                key: const ValueKey('chat-image-button'),
                width: 44,
                height: 44,
                child: IconButton(
                  tooltip: _selectedSticker != null
                      ? '已选择表情'
                      : _isSendingMedia
                          ? '图片发送中'
                          : '添加图片',
                  onPressed: blocked ||
                          _selectedSticker != null ||
                          _isPickingImage ||
                          _isSendingMedia
                      ? null
                      : _pickAndSendImage,
                  padding: EdgeInsets.zero,
                  icon: _isPickingImage || _isSendingMedia
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
                  onKeyEvent: _handleComposerKeyEvent,
                  child: Container(
                    key: const ValueKey('chat-input-container'),
                    constraints: const BoxConstraints(minHeight: 46),
                    child: TextField(
                      key: const ValueKey('chat-input'),
                      controller: _textController,
                      focusNode: _inputFocusNode,
                      onTap: _showKeyboard,
                      enabled: !blocked,
                      readOnly: blocked,
                      style: TextStyle(
                        color: blocked
                            ? (isDark ? Colors.white38 : Colors.black38)
                            : (isDark ? Colors.white : const Color(0xFF111827)),
                      ),
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: blocked ? '等待对方回复后可继续发送' : '发送消息',
                        isDense: true,
                        filled: true,
                        fillColor: blocked
                            ? (isDark
                                ? const Color(0xFF2B313D)
                                : const Color(0xFFE5E7EB))
                            : (isDark
                                ? const Color(0xFF292F3A)
                                : const Color(0xFFF4F2F4)),
                        hintStyle: TextStyle(
                          color: isDark
                              ? Colors.white38
                              : Colors.black.withValues(
                                  alpha: blocked ? 0.4 : 0.46,
                                ),
                        ),
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 44,
                          maxWidth: 44,
                          minHeight: 46,
                          maxHeight: 46,
                        ),
                        suffixIcon: SizedBox(
                          key: const ValueKey('chat-emoji-button'),
                          width: 44,
                          height: 44,
                          child: IconButton(
                            tooltip: _bottomPanel == ChatBottomPanel.emoji
                                ? '打开键盘'
                                : '选择表情',
                            onPressed: blocked ? null : _toggleEmojiPanel,
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              _bottomPanel == ChatBottomPanel.emoji
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
                valueListenable: _textController,
                builder: (context, value, _) {
                  final canSend = !blocked &&
                      (value.text.trim().isNotEmpty || _selectedSticker != null);
                  return SizedBox(
                    key: const ValueKey('chat-send-button-container'),
                    width: 44,
                    height: 44,
                    child: AnimatedOpacity(
                      opacity: canSend ? 1 : 0,
                      duration: const Duration(milliseconds: 130),
                      curve: Curves.easeOut,
                      child: IgnorePointer(
                        ignoring: !canSend,
                        child: IconButton.filled(
                          key: const ValueKey('chat-send-button'),
                          tooltip: '发送',
                          onPressed: canSend ? _sendMessage : null,
                          style: IconButton.styleFrom(
                            fixedSize: const Size(44, 44),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            backgroundColor: AppTheme.primaryColor,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: AppTheme.primaryColor,
                            disabledForegroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.send_rounded, size: 20),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildComposerArea() {
    final inputBar = _buildInputBar();
    final composerContent = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_selectedSticker != null)
          StickerComposerPreview(
            sticker: _selectedSticker!,
            onRemove: _removeSelectedSticker,
            enabled: !_isComposerBlocked,
          ),
        inputBar,
      ],
    );
    if (_bottomPanel != ChatBottomPanel.none) return composerContent;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 空闲状态由 Composer 自身消费系统手势安全区，避免透明系统栏压住输入控件。
    return ColoredBox(
      color: isDark ? const Color(0xFF1B202A) : Colors.white,
      child: SafeArea(
        top: false,
        maintainBottomViewPadding: true,
        child: composerContent,
      ),
    );
  }

  Widget _buildPMLockedBanner() {
    final pendingFirstContact =
        _firstContactSendPending && !_isServerSendBlocked;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: const Color(0xFFFFF7E6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lock_outline,
            size: 14,
            color: Colors.orange.shade700,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              pendingFirstContact
                  ? '首条私信已提交。等待对方回复后可继续发送。'
                  : '对方未关注你。对方回复前，你只能发送 1 条消息。',
              style: TextStyle(
                fontSize: 12,
                color: Colors.orange.shade800,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
