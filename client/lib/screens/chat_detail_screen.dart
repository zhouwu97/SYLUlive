import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../services/emoji_favorite_repository.dart';
import '../services/emoji_favorite_service.dart';
import '../services/root_page_state_service.dart';
import '../utils/app_feedback.dart';
import '../theme/app_motion.dart';
import '../utils/app_navigation.dart';
import '../utils/app_navigator.dart';
import '../utils/app_time.dart';
import '../utils/chat_scroll_intent.dart';
import '../utils/text_editing_helper.dart';
import '../widgets/cached_avatar.dart';
import '../widgets/app_composer_bar.dart';
import '../widgets/emoji/app_emoji_panel.dart';
import '../widgets/emoji/sticker_catalog.dart';
import '../widgets/private_message_image.dart';
import '../widgets/state_placeholder.dart';
import '../widgets/swipe_to_exit.dart';
import 'image_viewer_screen.dart';

/// 聊天底部只有一个可见区域，避免键盘和表情面板分别驱动布局。
enum ChatBottomPanel { none, keyboard, emoji }

/// Emoji → Keyboard 切换时的内容连续性交接状态。
enum ChatInputHandoff { none, emojiToKeyboard }

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
  double _stableKeyboardHeight = _fallbackKeyboardHeight;
  Timer? _keyboardMetricsTimer;
  Timer? _messageFocusHighlightTimer;
  bool _hasObservedKeyboardHeight = false;
  bool _keyboardRequestPending = false;
  ChatBottomPanel _bottomPanel = ChatBottomPanel.none;
  ChatInputHandoff _handoff = ChatInputHandoff.none;
  int _handoffGeneration = 0;
  Timer? _keyboardHandoffTimer;
  bool _disposing = false;

  bool _isPickingImage = false;
  bool _isSendingMedia = false;
  bool _firstContactSendPending = false;
  DateTime _lastMessageActivity = DateTime.now();
  final Map<int, GlobalKey> _messageKeys = {};
  MessageSendState? _sendState;
  MessageProvider? _messageProvider;
  MessageRealtimeState _lastSeenRealtimeState =
      MessageRealtimeState.disconnected;
  bool _reconcilingOnReconnect = false;
  PageRoute<dynamic>? _subscribedRoute;
  bool _isRouteVisible = false;
  AppLifecycleState _lifecycleState =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  int? _lastObservedServerMessageId;
  int _newMessageCount = 0;
  int? _messageFocusHighlightId;
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
      _bottomPanel = ChatBottomPanel.none;
      _cancelHandoff();
      _keyboardRequestPending = false;
      _firstContactSendPending = false;
      _positionRequestVersion++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
    }
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    if (_subscribedRoute != null) {
      appRouteObserver.unsubscribe(this);
    }
    _messageProvider?.removeListener(_handleProviderMessagesChanged);
    _positionRequestVersion++;
    _deactivateConversation();
    _refreshTimer?.cancel();
    _messageProvider?.setFallbackPollingActive(false);
    _keyboardMetricsTimer?.cancel();
    _keyboardHandoffTimer?.cancel();
    _messageFocusHighlightTimer?.cancel();
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
      _cancelHandoff();
      _deactivateConversation();
    }
  }

  @override
  void didPush() {
    _isRouteVisible = true;
    // RouteObserver.subscribe 在 build 期间同步触发 didPush；
    // _startPolling 会 notifyListeners，必须延迟到帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _activateConversationIfVisible();
    });
  }

  @override
  void didPopNext() {
    _isRouteVisible = true;
    unawaited(_restoreConversationAfterRouteReturn());
  }

  @override
  void didPushNext() {
    _isRouteVisible = false;
    _cancelHandoff();
    _deactivateConversation();
  }

  @override
  void didPop() {
    _isRouteVisible = false;
    _cancelHandoff();
    _deactivateConversation();
    unawaited(_clearRestorableConversation());
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

      // Emoji → Keyboard 交接期间保持 Emoji 可见，直到 IME 覆盖到稳定高度
      // 再完成交接；不让 Emoji 面板在 IME 升起途中让位造成空白板。
      if (_handoff == ChatInputHandoff.emojiToKeyboard) {
        if (keyboardInset > 0) {
          _scheduleStableKeyboardHeight(keyboardInset);
        }
        return;
      }

      if (_bottomPanel == ChatBottomPanel.emoji) {
        return;
      }

      if (keyboardInset <= 0) {
        _keyboardMetricsTimer?.cancel();
        _cancelHandoff();
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
        (keyboardInset >= _stableKeyboardHeight ||
            !_hasObservedKeyboardHeight)) {
      _keyboardMetricsTimer?.cancel();
      setState(() {
        _stableKeyboardHeight = keyboardInset;
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
          _hasObservedKeyboardHeight = true;
          _keyboardRequestPending = false;
          if (_handoff == ChatInputHandoff.emojiToKeyboard) {
            // IME 稳定后完成 Emoji → Keyboard 交接，Emoji 让位给键盘。
            _completeEmojiToKeyboardHandoff();
            return;
          }
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
    final provider = _messageProvider;
    // SSE 健康时不做固定轮询，只做实时 + 事件驱动 reconciliation。
    if (provider != null &&
        provider.realtimeState == MessageRealtimeState.connected) {
      provider.setFallbackPollingActive(false);
      return;
    }
    _refreshTimer = Timer(_pollDelay, () async {
      await _refreshMessages();
      if (mounted && _isChatActive) _startPolling();
    });
    provider?.setFallbackPollingActive(true);
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

  /// SSE 重新连上后执行一次 REST reconciliation，覆盖当前会话与列表摘要。
  Future<void> _reconcileAfterReconnect() async {
    if (_reconcilingOnReconnect) return;
    _reconcilingOnReconnect = true;
    try {
      if (!mounted || !_isChatActive) return;
      final provider = context.read<MessageProvider>();
      await provider.refreshMessages();
      await provider.loadConversations(silent: true);
    } finally {
      _reconcilingOnReconnect = false;
    }
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

  /// 键盘、Emoji 或 handoff 未结束期间视为输入面板活跃，
  /// 用于系统返回拦截与禁用退出滑动。
  bool get _inputPanelActive =>
      _bottomPanel != ChatBottomPanel.none ||
      _handoff != ChatInputHandoff.none;

  bool get _canStartOutgoingMessage => !_isComposerBlocked;

  void _reserveFirstContactAllowanceIfNeeded() {
    if (!(_sendState?.canUseFirstContactAllowance ?? false)) return;
    _cancelHandoff();
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
    if (!_canStartOutgoingMessage || content.isEmpty) return;
    if (content.runes.length > MessageProvider.maxMessageLength) {
      AppFeedback.showSnackBar(
        context,
        '消息内容不能超过${MessageProvider.maxMessageLength}个字符',
        isError: true,
      );
      return;
    }

    final provider = context.read<MessageProvider>();
    _reserveFirstContactAllowanceIfNeeded();

    _textController.clear();
    provider.clearDraft(widget.targetUser.id);
    final sendFuture = provider.sendMessage(
      widget.targetUser.id,
      content,
      senderId: context.read<AuthProvider>().user?.id,
    );
    _lastMessageActivity = DateTime.now();
    unawaited(_scrollToLatestMessage(intent: ChatScrollIntent.ownSend));
    unawaited(_completeOutgoingSend(sendFuture));
  }

  /// Sticker 点击即独立发送，不清空输入框里已输入的文字。
  void _sendSticker(AppSticker sticker) {
    if (!_canStartOutgoingMessage) return;
    _reserveFirstContactAllowanceIfNeeded();
    final sendFuture = context.read<MessageProvider>().sendStickerMessage(
          widget.targetUser.id,
          sticker.id,
          senderId: context.read<AuthProvider>().user?.id,
        );
    _lastMessageActivity = DateTime.now();
    unawaited(_scrollToLatestMessage(intent: ChatScrollIntent.ownSend));
    unawaited(_completeOutgoingSend(sendFuture));
  }

  /// 收藏图片/GIF 点击即独立发送，不清空输入框里已输入的文字。
  void _sendFavorite(EmojiFavoriteItem favorite) {
    if (!_canStartOutgoingMessage) return;
    _reserveFirstContactAllowanceIfNeeded();
    final sendFuture = context.read<MessageProvider>().sendFavoriteImageMessage(
          widget.targetUser.id,
          favorite,
          senderId: context.read<AuthProvider>().user?.id,
        );
    _lastMessageActivity = DateTime.now();
    unawaited(_scrollToLatestMessage(intent: ChatScrollIntent.ownSend));
    unawaited(_completeOutgoingSend(sendFuture));
  }

  Future<void> _pickAndSendImage() async {
    if (!_canStartOutgoingMessage || _isPickingImage || _isSendingMedia) {
      return;
    }
    // 打开系统相册前先收输入态；取消回来保持 panel none、不自动抢焦点。
    _collapseBottomPanelOnly();
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
      unawaited(_scrollToLatestMessage(intent: ChatScrollIntent.ownSend));
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

  Future<void> _pickAndAddFavoriteImage() async {
    if (!_canStartOutgoingMessage || _isPickingImage || _isSendingMedia) {
      return;
    }
    setState(() => _isPickingImage = true);
    try {
      // 不在客户端指定 imageQuality，避免 ImagePicker 将 GIF 转成静态图；
      // 服务端负责统一压缩尺寸、逐帧处理和配额校验。
      final image = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (image == null || !mounted) return;
      final provider = context.read<MessageProvider>();
      setState(() => _isSendingMedia = true);
      final fileId = await provider.uploadImage(image);
      await EmojiFavoriteService.instance.addCustomFromUpload(fileId);
      if (mounted) {
        AppFeedback.showSnackBar(context, '已添加到表情包');
      }
    } on EmojiFavoriteException catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(context, error.message, isError: true);
      }
    } catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '添加表情包失败', isError: true);
      }
      debugPrint('添加自定义表情失败: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isPickingImage = false;
          _isSendingMedia = false;
        });
      }
    }
  }

  void _retryMessage(Message message) {
    final clientMessageId = message.clientMessageId;
    if (clientMessageId == null) return;
    unawaited(_scrollToLatestMessage(intent: ChatScrollIntent.ownSend));
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
    if (next?.isBlocked ?? false) {
      _cancelHandoff();
    }
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
    _cancelHandoff();
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    setState(() {
      if (keyboardInset > 0) {
        _stableKeyboardHeight = keyboardInset;
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
    if (_bottomPanel == ChatBottomPanel.emoji) {
      // Emoji → Keyboard：保持 Emoji 原位直到 IME 覆盖，避免空白板。
      _beginEmojiToKeyboardHandoff();
      return;
    }
    setState(() {
      _bottomPanel = ChatBottomPanel.keyboard;
      _keyboardRequestPending = true;
    });
    _inputFocusNode.requestFocus();
  }

  /// 发起 Emoji → Keyboard 交接：Emoji 保持显示直到 IME 稳定高度出现。
  void _beginEmojiToKeyboardHandoff() {
    _cancelHandoff();
    final generation = ++_handoffGeneration;
    setState(() {
      _handoff = ChatInputHandoff.emojiToKeyboard;
      _keyboardRequestPending = true;
    });
    _inputFocusNode.requestFocus();
    // 保险超时：仅防状态永远卡住，不作为动画时长。
    _keyboardHandoffTimer = Timer(
      const Duration(milliseconds: 700),
      () {
        if (!mounted || generation != _handoffGeneration) return;
        if (_handoff == ChatInputHandoff.emojiToKeyboard) {
          setState(() {
            _handoff = ChatInputHandoff.none;
            _bottomPanel = ChatBottomPanel.keyboard;
          });
        }
      },
    );
  }

  /// handoff 完成后调用：Emoji 让位给已稳定的 IME。
  void _completeEmojiToKeyboardHandoff() {
    _keyboardHandoffTimer?.cancel();
    if (_handoff != ChatInputHandoff.emojiToKeyboard) return;
    _handoffGeneration++;
    setState(() {
      _handoff = ChatInputHandoff.none;
      _bottomPanel = ChatBottomPanel.keyboard;
      _keyboardRequestPending = false;
    });
  }

  void _cancelHandoff() {
    _keyboardHandoffTimer?.cancel();
    if (_handoff != ChatInputHandoff.none) {
      _handoffGeneration++;
      if (_disposing) {
        _handoff = ChatInputHandoff.none;
        return;
      }
      setState(() => _handoff = ChatInputHandoff.none);
    }
  }

  void _dismissBottomPanel() {
    _inputFocusNode.unfocus();
    _cancelHandoff();
    if (_bottomPanel == ChatBottomPanel.none &&
        _keyboardRequestPending == false) {
      return;
    }
    setState(() {
      _bottomPanel = ChatBottomPanel.none;
      _keyboardRequestPending = false;
    });
  }

  /// 仅关闭当前底部面板（消息区点击、返回等），不退出页面。
  void _collapseBottomPanelOnly() {
    _inputFocusNode.unfocus();
    _cancelHandoff();
    if (_bottomPanel == ChatBottomPanel.none) return;
    setState(() {
      _bottomPanel = ChatBottomPanel.none;
      _keyboardRequestPending = false;
    });
  }

  /// 顶部 ←：与系统返回不同，一次直接退出聊天。
  void _exitChat() {
    _cancelHandoff();
    _inputFocusNode.unfocus();
    setState(() {
      _bottomPanel = ChatBottomPanel.none;
      _keyboardRequestPending = false;
    });
    // 下一帧再 pop，避免 PopScope 仍看到旧的底部面板状态。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop();
    });
  }

  void _insertEmoji(String emoji) {
    if (_isComposerBlocked) return;
    insertAtSelection(_textController, emoji);
    _saveDraft();
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
    // Emoji → Keyboard handoff 期间 _bottomPanel 仍是 emoji，面板保持显示
    // 直到 IME 覆盖；__showEmojiPanel__ 不随键盘面板切换而翻转。
    final showEmojiPanel =
        _bottomPanel == ChatBottomPanel.emoji && !_isComposerBlocked;
    final colors = Theme.of(context).colorScheme;
    final emojiPanel = AppEmojiPanel(
      key: const ValueKey('chat-emoji-panel'),
      onEmojiSelected: _insertEmoji,
      onStickerSelected: _sendSticker,
      onFavoriteImageSelected: _sendFavorite,
      onAddImage: _pickAndAddFavoriteImage,
      favoriteImageHeaders: _privateMediaHeaders(),
      onBackspace: () => deletePreviousCharacter(_textController),
      // 媒体上传不应冻结 Emoji 或 Sticker 的连续发送能力。
      enabled: !_isComposerBlocked && !_isPickingImage && !_isSendingMedia,
    );
    // 表情面板常驻同一棵子树，用 Offstage 控制可见性而非销毁重建，
    // 确保收藏页 / tab / PageView / scroll offset 在键盘切换间不丢状态。
    // Keyboard ↔ Emoji 本身不做额外过渡动画。
    return SizedBox(
      key: const ValueKey('chat-bottom-viewport'),
      width: double.infinity,
      height: height,
      child: ColoredBox(
        color: colors.surface,
        child: Offstage(
          offstage: !showEmojiPanel,
          child: IgnorePointer(
            ignoring: !showEmojiPanel,
            child: SafeArea(
              top: false,
              child: emojiPanel,
            ),
          ),
        ),
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
    _cancelHandoff();
    _messageProvider?.setFallbackPollingActive(false);
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

    // SSE 传输层状态变化：connected 时停止固定轮询并执行一次 REST
    // reconciliation；断开时恢复 fallback polling（页面仍活跃时）。
    if (provider.realtimeState != _lastSeenRealtimeState) {
      _lastSeenRealtimeState = provider.realtimeState;
      if (provider.realtimeState == MessageRealtimeState.connected) {
        _refreshTimer?.cancel();
        provider.setFallbackPollingActive(false);
        if (_isChatActive) {
          unawaited(_reconcileAfterReconnect());
        }
      } else {
        _startPolling();
      }
    }

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
        unawaited(_scrollToLatestMessage(
          intent: includesOwnMessage
              ? ChatScrollIntent.ownSend
              : ChatScrollIntent.incomingNearBottom,
        ));
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

      if (targetMessageId != null &&
          _ensureMessageVisible(
            targetMessageId,
            intent: ChatScrollIntent.restore,
          )) {
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

  bool _ensureMessageVisible(
    int targetMessageId, {
    ChatScrollIntent intent = ChatScrollIntent.messageFocus,
  }) {
    final targetContext = _messageKeys[targetMessageId]?.currentContext;
    if (targetContext == null) {
      _jumpNearMessage(targetMessageId);
      return false;
    }
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final shouldAnimate = intent.usesAnimatedFocus(reduceMotion: reduceMotion);
    Scrollable.ensureVisible(
      targetContext,
      duration: shouldAnimate ? AppMotion.fast : Duration.zero,
      alignment: 0.72,
      curve: AppMotion.standard,
    );
    if (intent.showsFocusHighlight) {
      _highlightMessage(targetMessageId);
    }
    return true;
  }

  void _highlightMessage(int messageId) {
    _messageFocusHighlightTimer?.cancel();
    if (!mounted) return;
    setState(() => _messageFocusHighlightId = messageId);
    _messageFocusHighlightTimer = Timer(AppMotion.normal, () {
      if (!mounted || _messageFocusHighlightId != messageId) return;
      setState(() => _messageFocusHighlightId = null);
    });
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
      if (_ensureMessageVisible(
        messageId,
        intent: ChatScrollIntent.messageFocus,
      )) {
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
    ChatScrollIntent intent = ChatScrollIntent.incomingNearBottom,
  }) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scrollController.hasClients) return;

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (intent.usesJumpScroll(reduceMotion: reduceMotion)) {
      _jumpToLatestMessage();
      return;
    }

    await _scrollController.animateTo(
      0,
      duration: AppMotion.tab,
      curve: AppMotion.standard,
    );
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
        canPop: !_inputPanelActive,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _inputPanelActive) {
            _collapseBottomPanelOnly();
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
      enabled: !_inputPanelActive,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _chatSystemOverlayStyle(isDark),
        child: PopScope(
          canPop: !_inputPanelActive,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && _inputPanelActive) {
              _collapseBottomPanelOnly();
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
    return Theme.of(context).colorScheme.surface;
  }

  SystemUiOverlayStyle _chatSystemOverlayStyle(bool isDark) {
    final colors = Theme.of(context).colorScheme;
    return (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
        .copyWith(
      statusBarColor: colors.surface,
      systemNavigationBarColor: colors.surfaceContainerHighest,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
    );
  }

  Widget _buildChatHeader({required bool showBackButton}) {
    final colors = Theme.of(context).colorScheme;
    final foreground = colors.onSurface;
    final muted = colors.onSurfaceVariant;
    final nickname = widget.targetUser.nickname.isEmpty
        ? '用户${widget.targetUser.id}'
        : widget.targetUser.nickname;
    return Container(
      key: const ValueKey('chat-header'),
      decoration: BoxDecoration(
        color: _chatSurfaceColor(),
        border: Border(
          bottom: BorderSide(
            color: colors.outlineVariant,
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
                        onPressed: _exitChat,
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
        const StatePlaceholder(
          key: ValueKey('chat-detail-loading'),
          loading: true,
          title: '加载消息中…',
          compact: true,
        ),
        includeBackdrop,
      );
    }
    if (provider.messageError != null && provider.messages.isEmpty) {
      return _wrapMessageBackdrop(
        StatePlaceholder(
          key: const ValueKey('chat-detail-error'),
          icon: Icons.cloud_off_outlined,
          title: '消息加载失败',
          subtitle: provider.messageError,
          actionLabel: '重新加载',
          onAction: _initialize,
          compact: true,
        ),
        includeBackdrop,
      );
    }
    if (provider.messages.isEmpty) {
      return _wrapMessageBackdrop(
        StatePlaceholder(
          key: const ValueKey('chat-detail-empty'),
          icon: Icons.waving_hand_outlined,
          title: '向 ${widget.targetUser.nickname} 打个招呼吧',
          subtitle: '发送第一条消息开始聊天',
          compact: true,
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
        _collapseBottomPanelOnly();
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
                  unawaited(_scrollToLatestMessage(
                    intent: ChatScrollIntent.incomingNearBottom,
                  ));
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
    final colors = Theme.of(context).colorScheme;
    final bgPath = themeProvider.getCustomBackgroundImageFor(context);
    if (!themeProvider.shouldShowCustomBackground ||
        bgPath == null ||
        bgPath.isEmpty) {
      return ColoredBox(
        color: colors.surface,
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
          color: (isDark ? colors.scrim : colors.surface)
              .withValues(alpha: isDark ? 0.28 : 0.15),
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
    final fallbackColor = Theme.of(context).colorScheme.surface;
    // 私信消息区始终铺满可视区域，避免 contain 模式在两侧留下暖白空隙。
    return Image(
      image: imageProvider,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => ColoredBox(color: fallbackColor),
    );
  }

  Widget _buildTimeLabel(DateTime time) {
    final colors = Theme.of(context).colorScheme;
    final local = AppTime.toShanghai(time);
    final now = AppTime.nowShanghai();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        DateFormat(sameDay ? 'HH:mm' : 'MM-dd HH:mm').format(local),
        style: TextStyle(
          fontSize: 12,
          color: colors.onSurfaceVariant,
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
    final privateMediaHeaders = _privateMediaHeaders();
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
    final colors = Theme.of(context).colorScheme;
    final bubbleColor =
        isMine ? colors.primary : colors.surfaceContainerHighest;
    final textColor = isMine ? colors.onPrimary : colors.onSurface;
    final groupGap = isGroupStart ? 10.0 : 4.0;
    final bubbleRadius = _messageBubbleRadius(
      isMine: isMine,
      isGroupStart: isGroupStart,
      isGroupEnd: isGroupEnd,
    );
    final isHighlighted = _messageFocusHighlightId == message.id;
    final highlightColor = isMine
        ? colors.onPrimary.withValues(alpha: 0.72)
        : colors.primary.withValues(alpha: 0.72);
    // 仅图片消息（无文字、无表情）不套普通气泡，图片自带圆角。
    final imageOnly = hasImage &&
        stickerUrl == null &&
        !message.hasTextContent;
    final chromeFree = message.isStickerOnly || imageOnly;

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
                    padding: chromeFree
                        ? EdgeInsets.zero
                        : const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                    decoration: BoxDecoration(
                      color: chromeFree ? Colors.transparent : bubbleColor,
                      borderRadius:
                          chromeFree ? BorderRadius.zero : bubbleRadius,
                      border: Border.all(
                        color: chromeFree
                            ? Colors.transparent
                            : isHighlighted
                                ? highlightColor
                                : isMine
                                    ? Colors.transparent
                                    : colors.outlineVariant,
                      ),
                      boxShadow: isHighlighted
                          ? [
                              BoxShadow(
                                color: highlightColor.withValues(alpha: 0.18),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                            ]
                          : null,
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
                            onTap: (imageUrl == null &&
                                    (localImagePath?.isNotEmpty ?? false) ==
                                        false)
                                ? null
                                : () {
                                    _collapseBottomPanelOnly();
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ImageViewerScreen(
                                          imageUrls:
                                              imageUrl == null ? [] : [imageUrl],
                                          localPaths: localImagePath
                                                      ?.isNotEmpty ==
                                                  true
                                              ? [localImagePath]
                                              : null,
                                          httpHeaders: privateMediaHeaders,
                                        ),
                                      ),
                                    );
                                  },
                            child: PrivateMessageImage(
                              networkUrl: message.imageUrl.isEmpty
                                  ? null
                                  : message.imageUrl,
                              localPath:
                                  localImagePath?.isNotEmpty == true
                                      ? localImagePath
                                      : null,
                              fileId: message.fileId,
                              serverWidth: message.file?.width ?? 0,
                              serverHeight: message.file?.height ?? 0,
                              httpHeaders: privateMediaHeaders,
                              maxWidth: (MediaQuery.sizeOf(context).width *
                                      0.64)
                                  .clamp(120.0, 260.0),
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

  Map<String, String> _privateMediaHeaders() {
    final token = context.read<AuthProvider>().token;
    if (token == null || token.isEmpty) {
      return const {};
    }
    return {'Authorization': 'Bearer $token'};
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

  Widget _buildMessageStatus(Message message) {
    final colors = Theme.of(context).colorScheme;
    if (message.isPending) {
      return Text(
        '发送中',
        key: const ValueKey('message-status-pending'),
        style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
      );
    }
    if (message.isFailed) {
      return Tooltip(
        message: message.localError ?? '发送失败',
        child: InkWell(
          key: ValueKey('retry-${message.stableKey}'),
          onTap: () => _retryMessage(message),
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Text(
              '发送失败 · 点击重试',
              style: TextStyle(fontSize: 11, color: colors.error),
            ),
          ),
        ),
      );
    }
    return Text(
      message.readAt == null ? '已送达' : '已读',
      key: ValueKey(
          'message-status-${message.readAt == null ? 'sent' : 'read'}'),
      style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
    );
  }

  Future<void> _showMessageActions(Message message, bool isMine) async {
    final canCopy = message.content.trim().isNotEmpty;
    final canDelete =
        isMine && message.isFailed && message.clientMessageId != null;
    final sticker = appStickerById(message.stickerId);
    final favoriteImageUrl =
        message.imageUrl.isEmpty ? null : message.imageUrl.trim();
    final canFavorite =
        sticker != null || (favoriteImageUrl != null && message.fileId != null);
    if (!canCopy && !canDelete && !canFavorite) return;

    final favoriteService = EmojiFavoriteService.instance;
    final isFavorite = sticker != null
        ? await favoriteService.containsSticker(sticker.id)
        : message.fileId != null
            ? await favoriteService.containsFile(message.fileId!)
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
          : await _toggleMessageFavorite(
              favoriteService,
              message,
              favoriteImageUrl,
              isFavorite,
            );
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
    if (_canStartOutgoingMessage &&
        _textController.text.trim().isNotEmpty) {
      _sendMessage();
    }
    return KeyEventResult.handled;
  }

  Widget _buildInputBar() {
    final blocked = _isComposerBlocked;
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (blocked) _buildPMLockedBanner(),
        AppComposerBar(
          composerKey: const ValueKey('chat-composer'),
          leadingKey: const ValueKey('chat-image-button'),
          inputContainerKey: const ValueKey('chat-input-container'),
          inputKey: const ValueKey('chat-input'),
          emojiKey: const ValueKey('chat-emoji-button'),
          sendContainerKey: const ValueKey('chat-send-button-container'),
          sendKey: const ValueKey('chat-send-button'),
          textController: _textController,
          focusNode: _inputFocusNode,
          hintText: blocked ? '等待对方回复后可继续发送' : '发送消息',
          leadingTooltip: _isSendingMedia ? '图片发送中' : '添加图片',
          onLeadingPressed:
              blocked || _isPickingImage || _isSendingMedia
                  ? null
                  : _pickAndSendImage,
          leadingLoading: _isPickingImage || _isSendingMedia,
          emojiPanelVisible: _bottomPanel == ChatBottomPanel.emoji,
          onEmojiPressed: blocked ? null : _toggleEmojiPanel,
          canSend: (value) => !blocked && value.text.trim().isNotEmpty,
          onSend: _sendMessage,
          onInputTap: _showKeyboard,
          onKeyEvent: _handleComposerKeyEvent,
          fieldEnabled: !blocked,
          readOnly: blocked,
          inputFillColor: blocked
              ? colors.surfaceContainerHigh
              : colors.surfaceContainerHighest,
          inputTextColor: blocked ? colors.onSurfaceVariant : colors.onSurface,
          hintColor: colors.onSurfaceVariant.withValues(
            alpha: blocked ? 0.7 : 1,
          ),
        ),
      ],
    );
  }

  Future<bool> _toggleMessageFavorite(
    EmojiFavoriteService service,
    Message message,
    String? imageUrl,
    bool isFavorite,
  ) async {
    if (isFavorite) {
      final items = await service.load();
      final existing = items.where((item) {
        if (item.type != EmojiFavoriteType.image) return false;
        return message.fileId != null
            ? item.fileId == message.fileId
            : item.imageUrl == imageUrl;
      });
      if (existing.isNotEmpty) await service.remove(existing.first);
      return false;
    }
    if (message.id > 0 && service.repository != null) {
      await service.addFromMessage(message.id);
      return true;
    }
    if (imageUrl == null || imageUrl.isEmpty) return false;
    return service.toggleImage(imageUrl);
  }

  Widget _buildComposerArea() {
    final inputBar = _buildInputBar();
    final composerContent = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        inputBar,
      ],
    );
    final panelHidden = _bottomPanel == ChatBottomPanel.none;
    final colors = Theme.of(context).colorScheme;
    // 保持 Composer 子树结构稳定，避免面板切换时重建 EditableText 并断开 IME。
    return ColoredBox(
      color: colors.surface,
      child: SafeArea(
        top: false,
        bottom: panelHidden,
        maintainBottomViewPadding: panelHidden,
        child: composerContent,
      ),
    );
  }

  Widget _buildPMLockedBanner() {
    final pendingFirstContact =
        _firstContactSendPending && !_isServerSendBlocked;
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: colors.errorContainer,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.lock_outline,
            size: 14,
            color: colors.onErrorContainer,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              pendingFirstContact
                  ? '首条私信已提交。等待对方回复后可继续发送。'
                  : '对方未关注你。对方回复前，你只能发送 1 条消息。',
              style: TextStyle(
                fontSize: 12,
                color: colors.onErrorContainer,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
