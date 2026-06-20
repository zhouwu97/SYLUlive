import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../models/conversation.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import '../utils/app_feedback.dart';
import '../utils/app_time.dart';
import '../widgets/cached_avatar.dart';
import 'image_viewer_screen.dart';

class ChatDetailScreen extends StatefulWidget {
  final int? conversationId;
  final User targetUser;
  final bool embedded;

  const ChatDetailScreen({
    super.key,
    this.conversationId,
    required this.targetUser,
    this.embedded = false,
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
  bool _loadingOlder = false;
  double _lastKeyboardInset = 0;
  DateTime _lastMessageActivity = DateTime.now();

  @override
  void initState() {
    super.initState();
    _conversationId = widget.conversationId;
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _textController.addListener(_saveDraft);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    if (!mounted) return;
    final provider = context.read<MessageProvider>();
    final draft = provider.draftFor(widget.targetUser.id);
    if (draft.isNotEmpty && _textController.text.isEmpty) {
      _textController.text = draft;
      _textController.selection = TextSelection.collapsed(offset: draft.length);
    }
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
          _scrollToBottom(jump: true);
        }
      }
    } else {
      await provider.loadMessages(_conversationId!, preferCache: true);
      if (!mounted) return;
      _scrollToBottom(jump: true);
    }
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
        _scrollToBottom();
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
    final oldLastId = context.read<MessageProvider>().messages.lastOrNull?.id;
    await context.read<MessageProvider>().refreshMessages();
    if (!mounted) return;
    final newLastId = context.read<MessageProvider>().messages.lastOrNull?.id;
    if (wasNearBottom && oldLastId != newLastId) {
      _lastMessageActivity = DateTime.now();
      _scrollToBottom();
    }
  }

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    return _scrollController.position.maxScrollExtent -
            _scrollController.position.pixels <
        120;
  }

  void _handleScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels <= 80) {
      _loadOlderMessages();
    }
  }

  Future<void> _loadOlderMessages() async {
    final provider = context.read<MessageProvider>();
    if (_loadingOlder || !provider.hasMore || provider.messages.isEmpty) return;

    _loadingOlder = true;
    final oldMaxExtent = _scrollController.position.maxScrollExtent;
    await provider.loadOlderMessages();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final addedExtent =
          _scrollController.position.maxScrollExtent - oldMaxExtent;
      if (addedExtent > 0) {
        _scrollController.jumpTo(addedExtent);
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
    _lastMessageActivity = DateTime.now();
    _textController.clear();
    _startPolling();
    _scrollToBottom();
  }

  void _saveDraft() {
    if (!mounted) return;
    context
        .read<MessageProvider>()
        .updateDraft(widget.targetUser.id, _textController.text);
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
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
        color: Theme.of(context).colorScheme.surface,
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
      appBar: AppBar(title: _buildTitle()),
      body: body,
    );
  }

  Widget _buildConversationBody(
    MessageProvider provider,
    int currentUserId,
    User? currentUser,
  ) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Expanded(
            child: _buildMessageArea(provider, currentUserId, currentUser),
          ),
          _buildInputBar(provider),
        ],
      ),
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
    final divider = Theme.of(context).dividerColor.withValues(alpha: 0.36);
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
        border: Border(bottom: BorderSide(color: divider)),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _buildTitle(),
      ),
    );
  }

  Widget _buildMessageArea(
    MessageProvider provider,
    int currentUserId,
    User? currentUser,
  ) {
    if (provider.messageLoading && provider.messages.isEmpty) {
      return _buildMessageBackdrop(
        const Center(child: CircularProgressIndicator()),
      );
    }
    if (provider.messageError != null && provider.messages.isEmpty) {
      return _buildMessageBackdrop(
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
      );
    }
    if (provider.messages.isEmpty) {
      return _buildMessageBackdrop(
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
      );
    }

    return _buildMessageBackdrop(
      ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: provider.messages.length + (provider.loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (provider.loadingMore && index == 0) {
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
          final messageIndex = index - (provider.loadingMore ? 1 : 0);
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
    );
  }

  Widget _buildMessageBackdrop(Widget child) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned.fill(child: _buildChatBackground()),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: isDark
                    ? [
                        Colors.black.withValues(alpha: 0.48),
                        Colors.black.withValues(alpha: 0.62),
                      ]
                    : [
                        Colors.white.withValues(alpha: 0.34),
                        Colors.white.withValues(alpha: 0.50),
                      ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }

  Widget _buildChatBackground() {
    const fallback = 'assets/images/morenbeijing.jpeg';
    final background = widget.targetUser.background;
    if (background.isEmpty) {
      return Image.asset(fallback, fit: BoxFit.cover);
    }

    return CachedNetworkImage(
      imageUrl: ApiConstants.fullUrl(background),
      fit: BoxFit.cover,
      placeholder: (_, __) => Image.asset(fallback, fit: BoxFit.cover),
      errorWidget: (_, __, ___) => Image.asset(fallback, fit: BoxFit.cover),
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
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.4),
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
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '发送消息',
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.55),
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
