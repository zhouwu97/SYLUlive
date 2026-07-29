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
import '../utils/app_feedback.dart';
import '../utils/app_navigator.dart';
import '../utils/app_time.dart';
import '../utils/text_editing_helper.dart';
import '../widgets/cached_avatar.dart';
import '../widgets/emoji/app_emoji_panel.dart';
import '../widgets/emoji/sticker_composer_preview.dart';
import '../widgets/emoji/sticker_catalog.dart';
import 'image_viewer_screen.dart';

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
  double _lastKeyboardHeight = 280;
  bool _showEmojiPanel = false;
  bool _isSending = false;
  AppSticker? _selectedSticker;
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
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
      final keyboardOpened = keyboardInset > _lastKeyboardInset;
      _lastKeyboardInset = keyboardInset;
      if (keyboardInset > 0) {
        _lastKeyboardHeight = keyboardInset.clamp(240.0, 320.0).toDouble();
      }
      if (keyboardOpened && _isNearBottom) {
        unawaited(_scrollToLatestMessage(jump: true, settle: true));
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

  Future<void> _sendMessage() async {
    final content = _textController.text.trim();
    final selectedSticker = _selectedSticker;
    if (_isSending || (content.isEmpty && selectedSticker == null)) return;
    if (content.runes.length > MessageProvider.maxMessageLength) {
      AppFeedback.showSnackBar(
        context,
        '消息内容不能超过${MessageProvider.maxMessageLength}个字符',
        isError: true,
      );
      return;
    }

    final provider = context.read<MessageProvider>();
    setState(() => _isSending = true);
    final sendFuture = provider.sendMessage(
      widget.targetUser.id,
      content,
      stickerId: selectedSticker?.id,
      senderId: context.read<AuthProvider>().user?.id,
    );
    _lastMessageActivity = DateTime.now();
    unawaited(_scrollToLatestMessage(settle: true));
    final message = await sendFuture;
    if (!mounted) return;
    setState(() => _isSending = false);
    if (message == null) {
      unawaited(_refreshSendState());
      return;
    }

    _textController.clear();
    setState(() => _selectedSticker = null);
    provider.clearDraft(widget.targetUser.id);

    _conversationId = message.conversationId;
    _activateConversationIfVisible();
    // 发送成功后，陌生人限制可能再次触发，刷新发送状态用于决定是否锁定输入
    unawaited(_refreshSendState());
    _startPolling();
    unawaited(_scrollToLatestMessage(settle: true));
  }

  Future<void> _pickAndSendImage() async {
    if ((_sendState?.isBlocked ?? false) ||
        _isSending ||
        _selectedSticker != null) {
      return;
    }
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 2048,
      );
      if (image == null || !mounted) return;
      final provider = context.read<MessageProvider>();
      final sendFuture = provider.sendImageMessage(
        widget.targetUser.id,
        image,
        senderId: context.read<AuthProvider>().user?.id,
      );
      _lastMessageActivity = DateTime.now();
      unawaited(_scrollToLatestMessage(settle: true));
      final message = await sendFuture;
      if (!mounted || message == null) return;
      _conversationId = message.conversationId;
      _activateConversationIfVisible();
      unawaited(_refreshSendState());
      _startPolling();
    } catch (error) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '选择图片失败', isError: true);
      debugPrint('选择私信图片失败: $error');
    }
  }

  Future<void> _retryMessage(Message message) async {
    final clientMessageId = message.clientMessageId;
    if (clientMessageId == null) return;
    unawaited(_scrollToLatestMessage(settle: true));
    final confirmed = await context.read<MessageProvider>().retryMessage(
          widget.targetUser.id,
          clientMessageId,
        );
    if (!mounted || confirmed == null) return;
    _conversationId = confirmed.conversationId;
    _activateConversationIfVisible();
    unawaited(_refreshSendState());
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
        _showEmojiPanel = false;
        _inputFocusNode.unfocus();
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
    if (_sendState?.isBlocked ?? false) return;
    final shouldKeepLatestVisible = _isNearBottom;
    if (_showEmojiPanel) {
      setState(() => _showEmojiPanel = false);
      _inputFocusNode.requestFocus();
      if (shouldKeepLatestVisible) {
        unawaited(_scrollToLatestMessage(jump: true));
      }
      return;
    }
    _inputFocusNode.unfocus();
    setState(() => _showEmojiPanel = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && shouldKeepLatestVisible) {
        unawaited(_scrollToLatestMessage(jump: true, settle: true));
      }
    });
  }

  void _insertEmoji(String emoji) {
    if (_sendState?.isBlocked ?? false) return;
    insertAtSelection(_textController, emoji);
    _saveDraft();
  }

  void _selectSticker(AppSticker sticker) {
    if ((_sendState?.isBlocked ?? false) || _isSending) return;
    final provider = context.read<MessageProvider>();
    setState(() => _selectedSticker = sticker);
    provider.updateDraftSticker(widget.targetUser.id, sticker.id);
  }

  void _removeSelectedSticker() {
    if (_isSending) return;
    setState(() => _selectedSticker = null);
    context.read<MessageProvider>().updateDraftSticker(
          widget.targetUser.id,
          null,
        );
  }

  double get _emojiPanelHeight {
    final screenHeight = MediaQuery.sizeOf(context).height;
    return _lastKeyboardHeight.clamp(220.0, screenHeight * 0.42).toDouble();
  }

  bool get _isChatActive =>
      _isRouteVisible && _lifecycleState == AppLifecycleState.resumed;

  void _activateConversationIfVisible() {
    final conversationId = _conversationId;
    if (!_isChatActive || conversationId == null) return;
    _messageProvider?.setActiveConversation(
      conversationId,
      embedded: widget.embedded,
    );
    unawaited(_syncCurrentConversationToPlatform(conversationId));
    _startPolling();
    unawaited(_markVisibleMessagesRead());
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
        canPop: !_showEmojiPanel,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _showEmojiPanel) {
            setState(() => _showEmojiPanel = false);
          }
        },
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              _buildEmbeddedHeader(),
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    return PopScope(
      canPop: !_showEmojiPanel,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _showEmojiPanel) {
          setState(() => _showEmojiPanel = false);
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: _buildTitle(),
          backgroundColor:
              isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight,
          foregroundColor: isDark ? Colors.white : const Color(0xFF111827),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        body: body,
      ),
    );
  }

  Widget _buildConversationBody(
    MessageProvider provider,
    int currentUserId,
    User? currentUser,
  ) {
    final content = AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Expanded(
            child: _buildMessageArea(
              provider,
              currentUserId,
              currentUser,
              includeBackdrop: widget.embedded,
            ),
          ),
          _buildInputBar(),
        ],
      ),
    );

    if (widget.embedded) return content;

    return Stack(
      children: [
        Positioned.fill(child: _buildStandaloneMessageBackdrop()),
        content,
      ],
    );
  }

  Widget _buildTitle() {
    return Row(
      children: [
        CachedAvatar(
          imageUrl: widget.targetUser.avatar.isEmpty
              ? null
              : ApiConstants.fullUrl(widget.targetUser.avatar),
          radius: 17,
          fallbackText: widget.targetUser.nickname,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            widget.targetUser.nickname.isEmpty
                ? '用户${widget.targetUser.id}'
                : widget.targetUser.nickname,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildEmbeddedHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final divider = Colors.black.withValues(alpha: 0.08);
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight,
        border: Border(bottom: BorderSide(color: divider)),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: DefaultTextStyle.merge(
          style:
              TextStyle(color: isDark ? Colors.white : const Color(0xFF111827)),
          child: _buildTitle(),
        ),
      ),
    );
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
        _inputFocusNode.unfocus();
        if (_showEmojiPanel) setState(() => _showEmojiPanel = false);
      },
      child: ListView.builder(
          controller: _scrollController,
          reverse: true,
          padding: EdgeInsets.fromLTRB(
            12,
            widget.embedded
                ? 12
                : MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
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
    if (widget.embedded) {
      return Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child,
        ],
      );
    }

    return Stack(
      children: [
        Positioned.fill(child: _buildStandaloneMessageBackdrop()),
        child,
      ],
    );
  }

  Widget _buildStandaloneMessageBackdrop() {
    return Stack(
      children: [
        Positioned.fill(child: _buildChatBackground()),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.30),
                  Colors.white.withValues(alpha: 0.46),
                ],
              ),
            ),
          ),
        ),
      ],
    );
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
          fillScreen: themeProvider.getCustomBackgroundFillScreenFor(context),
        ),
        Container(color: Colors.white.withValues(alpha: 0.22)),
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
    required bool fillScreen,
  }) {
    const fallbackColor = kCleanWarmBackgroundLight;
    if (fillScreen) {
      return Image(
        image: imageProvider,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const ColoredBox(color: fallbackColor),
      );
    }

    return ColoredBox(
      color: fallbackColor,
      child: Image(
        image: imageProvider,
        fit: BoxFit.contain,
        alignment: Alignment.center,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildTimeLabel(DateTime time) {
    final local = AppTime.toShanghai(time);
    final now = AppTime.nowShanghai();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        DateFormat(sameDay ? 'HH:mm' : 'MM-dd HH:mm').format(local),
        style: TextStyle(
          fontSize: 12,
          color: Colors.grey.shade700,
          shadows: const [Shadow(color: Colors.white, blurRadius: 6)],
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
    final colorScheme = Theme.of(context).colorScheme;
    final bubbleColor = isMine
        ? colorScheme.primary.withValues(alpha: isDark ? 0.28 : 0.14)
        : (isDark ? const Color(0xFF252B36) : const Color(0xFFF8F9FB));
    final textColor = isDark ? Colors.white : const Color(0xFF111827);
    final groupGap = isGroupStart ? 7.0 : 2.0;
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
                            horizontal: 13,
                            vertical: 9,
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
                                ? colorScheme.primary.withValues(alpha: 0.12)
                                : Colors.black.withValues(alpha: 0.05),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (stickerUrl != null)
                          _buildStickerImage(stickerUrl, message.stickerId),
                        if (hasImage)
                          GestureDetector(
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
                                height: 1.35,
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
          if (isMine) ...[
            const SizedBox(width: 8),
            _buildMessageAvatarSlot(
              showAvatar: showAvatar,
              imageUrl: senderAvatar,
              fallbackText: senderName,
            ),
          ],
        ],
      ),
    );
  }

  BorderRadius _messageBubbleRadius({
    required bool isMine,
    required bool isGroupStart,
    required bool isGroupEnd,
  }) {
    const outer = Radius.circular(16);
    const grouped = Radius.circular(6);
    const tail = Radius.circular(4);
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
      width: 36,
      height: 36,
      child: showAvatar
          ? CachedAvatar(
              imageUrl: imageUrl,
              radius: 18,
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
    return CachedNetworkImage(
      key: ValueKey('message-sticker-$imageUrl'),
      imageUrl: imageUrl,
      width: 156,
      height: 156,
      fit: BoxFit.contain,
      placeholder: (_, __) => localSticker == null
          ? const SizedBox(
              width: 156,
              height: 156,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          : Image.asset(
              localSticker.thumbnailAsset,
              width: 156,
              height: 156,
              fit: BoxFit.contain,
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
    if (!canCopy && !canDelete) return;

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
    }
  }

  KeyEventResult _handleComposerKeyEvent(FocusNode node, KeyEvent event) {
    final platform = Theme.of(context).platform;
    final isDesktop = platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
    if (!isDesktop ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.enter ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final composing = _textController.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (!(_sendState?.isBlocked ?? false) &&
        !_isSending &&
        (_textController.text.trim().isNotEmpty || _selectedSticker != null)) {
      unawaited(_sendMessage());
    }
    return KeyEventResult.handled;
  }

  Widget _buildInputBar() {
    final blocked = _sendState?.isBlocked ?? false;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (blocked) _buildPMLockedBanner(),
          if (_selectedSticker != null && !blocked)
            StickerComposerPreview(
              sticker: _selectedSticker!,
              onRemove: _removeSelectedSticker,
              enabled: !_isSending,
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
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
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  key: const ValueKey('chat-image-button'),
                  width: 44,
                  height: 44,
                  child: IconButton(
                    tooltip: '选择图片',
                    onPressed: blocked || _isSending || _selectedSticker != null
                        ? null
                        : _pickAndSendImage,
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Focus(
                    onKeyEvent: _handleComposerKeyEvent,
                    child: Container(
                      key: const ValueKey('chat-input-container'),
                      constraints: const BoxConstraints(minHeight: 44),
                      child: TextField(
                        key: const ValueKey('chat-input'),
                        controller: _textController,
                        focusNode: _inputFocusNode,
                        onTap: () {
                          final shouldKeepLatestVisible = _isNearBottom;
                          if (_showEmojiPanel) {
                            setState(() => _showEmojiPanel = false);
                          }
                          if (shouldKeepLatestVisible) {
                            unawaited(_scrollToLatestMessage(settle: true));
                          }
                        },
                        enabled: !blocked && !_isSending,
                        readOnly: blocked || _isSending,
                        style: TextStyle(
                          color: blocked
                              ? (isDark ? Colors.white38 : Colors.black38)
                              : (isDark
                                  ? Colors.white
                                  : const Color(0xFF111827)),
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
                                  : const Color(0xFFF1F0F6)),
                          hintStyle: TextStyle(
                            color: isDark
                                ? Colors.white38
                                : Colors.black.withValues(
                                    alpha: blocked ? 0.4 : 0.46,
                                  ),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  key: const ValueKey('chat-emoji-button'),
                  width: 44,
                  height: 44,
                  child: IconButton(
                    tooltip: _showEmojiPanel ? '打开键盘' : '选择表情',
                    onPressed: blocked || _isSending ? null : _toggleEmojiPanel,
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      _showEmojiPanel
                          ? Icons.keyboard_alt_outlined
                          : Icons.sentiment_satisfied_alt_outlined,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _textController,
                  builder: (context, value, _) {
                    final canSend = !blocked &&
                        !_isSending &&
                        (value.text.trim().isNotEmpty ||
                            _selectedSticker != null);
                    return SizedBox(
                      key: const ValueKey('chat-send-button-container'),
                      width: 44,
                      height: 44,
                      child: IconButton.filled(
                        key: const ValueKey('chat-send-button'),
                        tooltip: '发送',
                        onPressed: canSend ? _sendMessage : null,
                        style: IconButton.styleFrom(
                          fixedSize: const Size(44, 44),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                        icon: const Icon(Icons.send_rounded),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: _showEmojiPanel && !blocked
                ? SizedBox(
                    height: _emojiPanelHeight,
                    child: AppEmojiPanel(
                      onEmojiSelected: _insertEmoji,
                      onStickerSelected: _selectSticker,
                      onBackspace: () =>
                          deletePreviousCharacter(_textController),
                      enabled: !_isSending,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _buildPMLockedBanner() {
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
              '对方未关注你。对方回复前，你只能发送 1 条消息。',
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
