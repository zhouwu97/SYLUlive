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

  const ChatDetailScreen({
    super.key,
    this.conversationId,
    required this.targetUser,
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

  @override
  void initState() {
    super.initState();
    _conversationId = widget.conversationId;
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    if (!mounted) return;
    final provider = context.read<MessageProvider>();
    if (_conversationId == null) {
      provider.prepareNewConversation();
    } else {
      await provider.loadMessages(_conversationId!);
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

  void _startPolling() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshMessages(),
    );
  }

  Future<void> _refreshMessages() async {
    if (!mounted || _conversationId == null) return;
    final wasNearBottom = _isNearBottom;
    final oldLastId = context.read<MessageProvider>().messages.lastOrNull?.id;
    await context.read<MessageProvider>().refreshMessages();
    if (!mounted) return;
    final newLastId = context.read<MessageProvider>().messages.lastOrNull?.id;
    if (wasNearBottom && oldLastId != newLastId) {
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
    _textController.clear();
    _scrollToBottom();
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
    final currentUserId = context.watch<AuthProvider>().user?.id ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Row(
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
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessageArea(provider, currentUserId)),
          _buildInputBar(provider),
        ],
      ),
    );
  }

  Widget _buildMessageArea(MessageProvider provider, int currentUserId) {
    if (provider.messageLoading && provider.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.messageError != null && provider.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(provider.messageError!),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _conversationId == null
                  ? provider.prepareNewConversation
                  : () => provider.loadMessages(_conversationId!),
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
    }
    if (provider.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.waving_hand_outlined,
                size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 14),
            Text(
              '向 ${widget.targetUser.nickname} 打个招呼吧',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
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
            message.createdAt.difference(previous.createdAt).inMinutes.abs() >=
                5;
        return Column(
          children: [
            if (showTime) _buildTimeLabel(message.createdAt),
            _buildMessageBubble(message, message.senderId == currentUserId),
          ],
        );
      },
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
        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
      ),
    );
  }

  Widget _buildMessageBubble(Message message, bool isMine) {
    final imageUrl = message.imageUrl.isEmpty
        ? null
        : ApiConstants.fullUrl(message.imageUrl);
    final bubbleColor = isMine
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    final textColor = isMine
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine) ...[
            CachedAvatar(
              imageUrl: widget.targetUser.avatar.isEmpty
                  ? null
                  : ApiConstants.fullUrl(widget.targetUser.avatar),
              radius: 18,
              fallbackText: widget.targetUser.nickname,
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
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMine ? 16 : 4),
                  bottomRight: Radius.circular(isMine ? 4 : 16),
                ),
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
                        style: TextStyle(color: textColor, height: 1.35),
                      ),
                    ),
                ],
              ),
            ),
          ),
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
                minLines: 1,
                maxLines: 5,
                maxLength: 2000,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '发送消息',
                  counterText: '',
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
