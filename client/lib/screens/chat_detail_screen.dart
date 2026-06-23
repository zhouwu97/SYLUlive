import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../models/conversation.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import '../providers/theme_provider.dart';
import '../services/upload_cache_recovery_service.dart';
import '../utils/app_feedback.dart';
import '../utils/app_time.dart';
import '../widgets/cached_avatar.dart';
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
    with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
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
  DateTime _lastMessageActivity = DateTime.now();
  final Map<int, GlobalKey> _messageKeys = {};
  static const MethodChannel _privateMessageNotificationsChannel =
      MethodChannel('shenliyuan/private_message_notifications');

  void _recoverImageUrl(String url) {
    try {
      UploadCacheRecoveryService.recover(
        imageUrl: url,
        dio: context.read<AuthProvider>().dio,
        cacheManager: DefaultCacheManager(),
      ).then((recovered) {
        if (recovered && mounted) setState(() {});
      }).catchError((_) {});
    } catch (_) {}
  }

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
            _syncCurrentConversationToPlatform(conversationId).ignore();
            await _markReadAndClearNotifications(conversationId);
            await _settleInitialPosition();
          }
        }
      } else {
        _syncCurrentConversationToPlatform(_conversationId).ignore();
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
        await _markReadAndClearNotifications(_conversationId!);
        await _settleInitialPosition();
      }
    } catch (error, stackTrace) {
      debugPrint('初始化聊天页面失败: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      if (mounted) {
        setState(() {
          _initialLoadFinished = true;
          _initialPositionSettled = true;
        });
      }
    }
    _startPolling();
  }

  @override
  void didUpdateWidget(covariant ChatDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedConversation =
        oldWidget.conversationId != widget.conversationId ||
            oldWidget.targetUser.id != widget.targetUser.id;
    if (changedConversation ||
        oldWidget.initialMessageId != widget.initialMessageId) {
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
    _positionRequestVersion++;
    _syncCurrentConversationToPlatform(null).ignore();
    _refreshTimer?.cancel();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _textController.removeListener(_saveDraft);
    _textController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshMessages();
      _startPolling();
    } else {
      _refreshTimer?.cancel();
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
      final keyboardOpened = keyboardInset > _lastKeyboardInset;
      _lastKeyboardInset = keyboardInset;
      if (keyboardOpened) {
        _scrollToBottom(jump: true, stable: true);
      }
    });
  }

  void _startPolling() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(_pollDelay, () async {
      await _refreshMessages();
      if (mounted) _startPolling();
    });
  }

  Duration get _pollDelay {
    final idle = DateTime.now().difference(_lastMessageActivity);
    if (idle < const Duration(minutes: 2)) return const Duration(seconds: 3);
    if (idle < const Duration(minutes: 10)) return const Duration(seconds: 10);
    return const Duration(seconds: 30);
  }

  Future<void> _refreshMessages() async {
    if (!mounted || _conversationId == null) return;
    final wasNearBottom = _isNearBottom;
    final currentUserId = context.read<AuthProvider>().user?.id;
    final oldLastId = context.read<MessageProvider>().messages.lastOrNull?.id;
    await context.read<MessageProvider>().refreshMessages(
          currentUserId: currentUserId,
        );
    if (!mounted) return;
    final newLastId = context.read<MessageProvider>().messages.lastOrNull?.id;
    if (wasNearBottom && oldLastId != newLastId) {
      _lastMessageActivity = DateTime.now();
      _scrollToBottom(stable: true);
    }
  }

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    return _scrollController.position.pixels < 120;
  }

  void _handleScroll() {
    if (!_initialPositionSettled) return;
    if (_scrollController.hasClients &&
        _scrollController.position.maxScrollExtent -
                _scrollController.position.pixels <=
            80) {
      _loadOlderMessages();
    }
  }

  Future<void> _loadOlderMessages() async {
    final provider = context.read<MessageProvider>();
    if (_loadingOlder || !provider.hasMore || provider.messages.isEmpty) return;

    _loadingOlder = true;
    final oldMaxExtent = _scrollController.position.maxScrollExtent;
    final oldPixels = _scrollController.position.pixels;
    await provider.loadOlderMessages();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final addedExtent =
          _scrollController.position.maxScrollExtent - oldMaxExtent;
      if (addedExtent > 0) {
        _scrollController.jumpTo(oldPixels + addedExtent);
      }
    });
    _loadingOlder = false;
  }

  Future<void> _sendMessage() async {
    final content = _textController.text.trim();
    if (content.isEmpty) return;
    if (content.runes.length > MessageProvider.maxMessageLength) {
      AppFeedback.showSnackBar(
        context,
        '消息内容不能超过${MessageProvider.maxMessageLength}个字符',
        isError: true,
      );
      return;
    }

    final provider = context.read<MessageProvider>();
    final message = await provider.sendMessage(widget.targetUser.id, content);
    if (!mounted) return;
    if (message == null) {
      AppFeedback.showSnackBar(
        context,
        provider.messageError ?? '发送失败，请稍后重试',
        isError: true,
      );
      return;
    }

    _conversationId = message.conversationId;
    _syncCurrentConversationToPlatform(_conversationId).ignore();
    _lastMessageActivity = DateTime.now();
    _textController.clear();
    _startPolling();
    _scrollToBottom(stable: true);
  }

  void _saveDraft() {
    if (!mounted) return;
    context
        .read<MessageProvider>()
        .updateDraft(widget.targetUser.id, _textController.text);
  }

  Future<void> _markReadAndClearNotifications(int conversationId) async {
    await context.read<MessageProvider>().markRead(conversationId);
    try {
      await _privateMessageNotificationsChannel.invokeMethod(
        'clearConversationNotifications',
        {'conversationId': conversationId},
      );
    } catch (e) {
      debugPrint('清理私信通知失败: $e');
    }
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

  Future<void> _settleInitialPosition() async {
    final targetMessageId = _initialMessageId;
    final requestVersion = ++_positionRequestVersion;
    await _settlePosition(
      requestVersion: requestVersion,
      targetMessageId: targetMessageId,
      jumpToBottomWhenMissing: true,
    ).timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
  }

  Future<void> _settlePosition({
    required int requestVersion,
    int? targetMessageId,
    bool jumpToBottomWhenMissing = false,
  }) async {
    var targetFound = false;
    for (var attempt = 0; attempt < 5; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          requestVersion != _positionRequestVersion ||
          _initialLoadFinished) {
        return;
      }

      if (targetMessageId != null && _ensureMessageVisible(targetMessageId)) {
        targetFound = true;
        continue;
      }

      if (targetMessageId == null || jumpToBottomWhenMissing) {
        _jumpToBottom();
      }
      await Future<void>.delayed(const Duration(milliseconds: 45));
    }

    if (!mounted ||
        requestVersion != _positionRequestVersion ||
        _initialLoadFinished) {
      return;
    }
    if (!targetFound && targetMessageId != null) {
      _jumpToBottom();
    }
    _initialPositionSettled = true;
  }

  bool _ensureMessageVisible(int targetMessageId) {
    if (_initialLoadFinished) return false;
    final targetContext = _messageKeys[targetMessageId]?.currentContext;
    if (targetContext == null) return false;
    Scrollable.ensureVisible(
      targetContext,
      duration: Duration.zero,
      alignment: 0.72,
      curve: Curves.easeOut,
    );
    return true;
  }

  void _jumpToBottom() {
    if (!mounted || !_scrollController.hasClients) return;
    _scrollController.jumpTo(0);
  }

  void _scrollToBottom({bool jump = false, bool stable = false}) {
    if (stable) {
      final requestVersion = ++_positionRequestVersion;
      _settlePosition(requestVersion: requestVersion);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      const target = 0.0;
      if (jump) {
        _scrollController.jumpTo(target);
      } else {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageProvider>();
    final currentUser = context.watch<AuthProvider>().user;
    final currentUserId = currentUser?.id ?? 0;

    final body = _buildConversationBody(provider, currentUserId, currentUser);
    if (widget.embedded) {
      return Material(
        color: Colors.transparent,
        child: Column(
          children: [
            _buildEmbeddedHeader(),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: _buildTitle(),
        backgroundColor: Colors.white.withValues(alpha: 0.30),
        foregroundColor: const Color(0xFF111827),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: body,
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
          _buildInputBar(provider),
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
    final divider = Colors.black.withValues(alpha: 0.08);
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.46),
        border: Border(bottom: BorderSide(color: divider)),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: DefaultTextStyle.merge(
          style: const TextStyle(color: Color(0xFF111827)),
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
              Icon(Icons.waving_hand_outlined,
                  size: 56, color: Colors.grey.shade500),
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

    return _wrapMessageBackdrop(
      ListView.builder(
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
          final showTime = previous == null ||
              message.createdAt
                      .difference(previous.createdAt)
                      .inMinutes
                      .abs() >=
                  5;
          return Column(
            key: _messageKeyFor(message.id),
            children: [
              if (showTime) _buildTimeLabel(message.createdAt),
              _buildMessageBubble(
                message,
                message.senderId == currentUserId,
                currentUser,
              ),
            ],
          );
        },
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
            child: ColoredBox(
              color: Colors.white.withValues(alpha: 0.18),
            ),
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
    final bgPath = themeProvider.getBackgroundImageFor(context);
    final imageProvider = _chatBackgroundImageProvider(bgPath);

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildChatBackgroundImage(
          imageProvider: imageProvider,
          fillScreen: bgPath != null &&
              themeProvider.getBackgroundFillScreenFor(context),
        ),
        Container(
          color: Colors.white.withValues(alpha: 0.22),
        ),
      ],
    );
  }

  ImageProvider _chatBackgroundImageProvider(String? bgPath) {
    if (bgPath == null || bgPath.isEmpty) {
      final isWide = MediaQuery.of(context).size.width >
          MediaQuery.of(context).size.height;
      return AssetImage(isWide
          ? 'assets/images/tablet_default_landscape.png'
          : 'assets/images/morenbeijing.jpeg');
    }

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
    const fallbackColor = Color(0xFFF4F6FB);
    if (fillScreen) {
      return Image(
        image: imageProvider,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const ColoredBox(color: fallbackColor),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform.scale(
          scale: 1.06,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Image(
              image: imageProvider,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                  const ColoredBox(color: fallbackColor),
            ),
          ),
        ),
        Image(
          image: imageProvider,
          fit: BoxFit.contain,
          alignment: Alignment.center,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
      ],
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
          shadows: const [
            Shadow(
              color: Colors.white,
              blurRadius: 6,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(Message message, bool isMine, User? currentUser) {
    final imageUrl = message.imageUrl.isEmpty
        ? null
        : ApiConstants.fullUrl(message.imageUrl);
    final sender = isMine ? currentUser : (message.sender ?? widget.targetUser);
    final senderAvatar = sender?.avatar.isEmpty ?? true
        ? null
        : ApiConstants.fullUrl(sender!.avatar);
    final senderName = sender?.nickname.isNotEmpty == true
        ? sender!.nickname
        : (isMine ? '我' : widget.targetUser.nickname);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine) ...[
            CachedAvatar(
              imageUrl: senderAvatar,
              radius: 18,
              fallbackText: senderName,
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.72,
              ),
              padding: imageUrl == null
                  ? const EdgeInsets.symmetric(horizontal: 13, vertical: 9)
                  : const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMine ? 16 : 4),
                  bottomRight: Radius.circular(isMine ? 4 : 16),
                ),
                border: Border.all(
                  color: Colors.black.withValues(alpha: 0.04),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (imageUrl != null)
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              ImageViewerScreen(imageUrls: [imageUrl]),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CachedNetworkImage(
                          imageUrl: imageUrl,
                          width: 210,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => const SizedBox(
                            width: 210,
                            height: 140,
                            child: Center(child: CircularProgressIndicator()),
                          ),
                          errorWidget: (_, url, ___) {
                            _recoverImageUrl(url);
                            return const SizedBox(
                              width: 210,
                              height: 140,
                              child: Icon(Icons.broken_image),
                            );
                          },
                        ),
                      ),
                    ),
                  if (message.content.isNotEmpty)
                    Padding(
                      padding: imageUrl == null
                          ? EdgeInsets.zero
                          : const EdgeInsets.fromLTRB(8, 7, 8, 6),
                      child: Text(
                        message.content,
                        style: const TextStyle(
                          color: Color(0xFF111827),
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (isMine) ...[
            const SizedBox(width: 8),
            CachedAvatar(
              imageUrl: senderAvatar,
              radius: 18,
              fallbackText: senderName,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputBar(MessageProvider provider) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(
            top: BorderSide(
              color: Colors.black.withValues(alpha: 0.06),
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                onTap: _scrollToBottom,
                style: const TextStyle(color: Color(0xFF111827)),
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '发送消息',
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0xFFF1F0F6),
                  hintStyle: TextStyle(
                    color: Colors.black.withValues(alpha: 0.46),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: provider.sending ? null : _sendMessage,
              icon: provider.sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

extension<T> on List<T> {
  T? get lastOrNull => isEmpty ? null : last;
}
