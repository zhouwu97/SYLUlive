import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import '../utils/app_time.dart';
import '../widgets/cached_avatar.dart';
import 'chat_detail_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with WidgetsBindingObserver {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<MessageProvider>().loadConversations();
      _startPolling();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<MessageProvider>().loadConversations(silent: true);
      _startPolling();
    } else {
      _refreshTimer?.cancel();
    }
  }

  void _startPolling() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) {
        context.read<MessageProvider>().loadConversations(silent: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = context.watch<AuthProvider>().user?.id ?? 0;
    final provider = context.watch<MessageProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('私信')),
      body: RefreshIndicator(
        onRefresh: () => provider.loadConversations(),
        child: _buildBody(provider, currentUserId),
      ),
    );
  }

  Widget _buildBody(MessageProvider provider, int currentUserId) {
    if (provider.conversationLoading && provider.conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (provider.conversationError != null && provider.conversations.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.22),
          Icon(Icons.cloud_off_outlined, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Center(child: Text(provider.conversationError!)),
          const SizedBox(height: 12),
          Center(
            child: FilledButton.tonal(
              onPressed: provider.loadConversations,
              child: const Text('重新加载'),
            ),
          ),
        ],
      );
    }

    if (provider.conversations.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.24),
          Icon(Icons.forum_outlined, size: 72, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              '暂无私信\n可以从其他用户主页发起聊天',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: provider.conversations.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 76),
      itemBuilder: (context, index) {
        final conversation = provider.conversations[index];
        final targetUser = conversation.getOtherUser(currentUserId);
        if (targetUser == null) {
          debugPrint(
            '私信会话数据异常: conversation=${conversation.id}, currentUser=$currentUserId, users=${conversation.user1Id}/${conversation.user2Id}',
          );
          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            leading: Icon(Icons.error_outline, color: Colors.red.shade400),
            title: const Text('会话数据异常'),
            subtitle: Text('会话 ${conversation.id} 无法匹配当前用户'),
          );
        }

        final lastMessage = conversation.lastMessage;
        final preview = lastMessage == null
            ? '暂无消息'
            : lastMessage.content.trim().isNotEmpty
                ? lastMessage.content.trim()
                : lastMessage.file != null
                    ? '[图片]'
                    : '暂无消息';

        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          leading: CachedAvatar(
            imageUrl: targetUser.avatar.isEmpty
                ? null
                : ApiConstants.fullUrl(targetUser.avatar),
            radius: 25,
            fallbackText: targetUser.nickname,
          ),
          title: Text(
            targetUser.nickname.isEmpty
                ? '用户${targetUser.id}'
                : targetUser.nickname,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.grey.shade600),
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatConversationTime(
                    lastMessage?.createdAt ?? conversation.lastMessageAt),
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 6),
              if (conversation.unreadCount > 0)
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.red.shade500,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    conversation.unreadCount > 99
                        ? '99+'
                        : '${conversation.unreadCount}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
            ],
          ),
          onTap: () async {
            final messageProvider = context.read<MessageProvider>();
            _refreshTimer?.cancel();
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatDetailScreen(
                  conversationId: conversation.id,
                  targetUser: targetUser,
                ),
              ),
            );
            if (mounted) {
              messageProvider.loadConversations(silent: true);
              _startPolling();
            }
          },
        );
      },
    );
  }

  String _formatConversationTime(DateTime time) {
    final local = AppTime.toShanghai(time);
    final now = AppTime.nowShanghai();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(local.year, local.month, local.day);
    final dayDifference = today.difference(date).inDays;

    if (dayDifference == 0) return DateFormat('HH:mm').format(local);
    if (dayDifference == 1) return '昨天';
    if (local.year == now.year) return DateFormat('MM-dd').format(local);
    return DateFormat('yyyy-MM-dd').format(local);
  }
}
