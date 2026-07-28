import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../models/conversation.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/message_provider.dart';
import '../providers/theme_provider.dart';
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
  int? _selectedConversationId;
  User? _selectedTargetUser;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (!auth.isLoggedIn) return;
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
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        context.read<MessageProvider>().loadConversations(silent: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    if (!auth.isLoggedIn) {
      _refreshTimer?.cancel();
      return _buildLoginRequiredScaffold();
    }

    final currentUserId = auth.user?.id ?? 0;
    final provider = context.watch<MessageProvider>();
    final isWide = MediaQuery.sizeOf(context).width >= 720;

    if (isWide) {
      _syncWideSelection(provider, currentUserId);
      return _buildWideLayout(provider, currentUserId);
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight,
      appBar: AppBar(
        title: const Text('私信'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      body: RefreshIndicator(
        onRefresh: () => provider.loadConversations(),
        child: _buildConversationList(provider, currentUserId),
      ),
    );
  }

  Widget _buildLoginRequiredScaffold() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF131720) : kCleanWarmBackgroundLight,
      appBar: AppBar(
        title: const Text('私信'),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline,
                size: 64,
                color: isDark ? Colors.white30 : Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                '登录后查看私信\n你收到的聊天、交易沟通和同学私信会显示在这里',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.grey[600],
                  fontSize: 16,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () async {
                  await Navigator.pushNamed(context, '/login');
                  if (mounted && context.read<AuthProvider>().isLoggedIn) {
                    context.read<MessageProvider>().loadConversations();
                    _startPolling();
                  }
                },
                icon: const Icon(Icons.login),
                label: const Text('去登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWideLayout(MessageProvider provider, int currentUserId) {
    final width = MediaQuery.sizeOf(context).width >= 1000 ? 320.0 : 292.0;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildPrivateMessageBackground(),
          Scaffold(
            backgroundColor: Colors.transparent,
            appBar: AppBar(
              title: const Text('私信'),
              backgroundColor: Colors.white.withValues(alpha: 0.20),
              foregroundColor: const Color(0xFF111827),
              surfaceTintColor: Colors.transparent,
              elevation: 0,
            ),
            body: Row(
              children: [
                SizedBox(
                  width: width,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.72),
                      border: Border(
                        right: BorderSide(
                          color: Colors.black.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    child: RefreshIndicator(
                      onRefresh: () => provider.loadConversations(),
                      child: _buildConversationList(
                        provider,
                        currentUserId,
                        splitMode: true,
                      ),
                    ),
                  ),
                ),
                Expanded(child: _buildWideDetailPane(provider)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivateMessageBackground() {
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

    final fillScreen = themeProvider.getCustomBackgroundFillScreenFor(context);
    final imageProvider = _privateMessageBackgroundProvider(bgPath);

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildPrivateMessageBackgroundImage(
          imageProvider: imageProvider,
          fillScreen: fillScreen,
        ),
        ColoredBox(color: Colors.white.withValues(alpha: 0.24)),
      ],
    );
  }

  ImageProvider _privateMessageBackgroundProvider(String bgPath) {
    if (ThemeProvider.isBundledAssetBackground(bgPath)) {
      return AssetImage(ThemeProvider.resolveBundledAssetPath(bgPath));
    }
    if (ThemeProvider.isLocalFileBackground(bgPath)) {
      return FileImage(File(bgPath));
    }
    return NetworkImage(bgPath);
  }

  Widget _buildPrivateMessageBackgroundImage({
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

  Widget _buildWideDetailPane(MessageProvider provider) {
    final selectedTarget = _selectedTargetUser;
    if (selectedTarget == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 72, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text('选择左侧会话开始聊天', style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      );
    }

    return ChatDetailScreen(
      key: ValueKey(
        'chat-detail-${_selectedConversationId ?? selectedTarget.id}',
      ),
      conversationId: _selectedConversationId,
      targetUser: selectedTarget,
      embedded: true,
    );
  }

  void _syncWideSelection(MessageProvider provider, int currentUserId) {
    if (provider.conversations.isEmpty) {
      if (_selectedTargetUser != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() {
            _selectedConversationId = null;
            _selectedTargetUser = null;
          });
        });
      }
      return;
    }

    final currentSelectionExists = _selectedConversationId != null &&
        provider.conversations.any(
          (conversation) => conversation.id == _selectedConversationId,
        );
    if (currentSelectionExists) return;

    final firstConversation = provider.conversations.first;
    final firstTarget = firstConversation.getOtherUser(currentUserId);
    if (firstTarget == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _selectedConversationId = firstConversation.id;
        _selectedTargetUser = firstTarget;
      });
    });
  }

  Widget _buildConversationList(
    MessageProvider provider,
    int currentUserId, {
    bool splitMode = false,
  }) {
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
            child: Text('暂无私信\n可以从其他用户主页发起聊天', textAlign: TextAlign.center),
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
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 7,
            ),
            leading: Icon(Icons.error_outline, color: Colors.red.shade400),
            title: const Text('会话数据异常'),
            subtitle: Text('会话 ${conversation.id} 无法匹配当前用户'),
          );
        }

        return _buildConversationTile(
          provider,
          conversation,
          targetUser,
          currentUserId: currentUserId,
          splitMode: splitMode,
        );
      },
    );
  }

  Widget _buildConversationTile(
    MessageProvider provider,
    Conversation conversation,
    User targetUser, {
    required int currentUserId,
    required bool splitMode,
  }) {
    final cachedMessage =
        provider.latestCachedMessageForConversation(conversation.id);
    final serverMessage = conversation.lastMessage;
    final lastMessage = cachedMessage != null &&
            (serverMessage == null ||
                !cachedMessage.createdAt.isBefore(serverMessage.createdAt))
        ? cachedMessage
        : serverMessage;
    final draft = provider.draftFor(targetUser.id).trim();
    final preview = _conversationPreview(
      message: lastMessage,
      draft: draft,
      currentUserId: currentUserId,
    );
    final previewIsAlert = draft.isNotEmpty || lastMessage?.isFailed == true;
    final selected = splitMode && _selectedConversationId == conversation.id;

    return ListTile(
      selected: selected,
      selectedTileColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.10),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
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
        style: TextStyle(
          color: previewIsAlert ? Colors.red.shade600 : Colors.grey.shade600,
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatConversationTime(
              draft.isNotEmpty
                  ? conversation.lastMessageAt
                  : lastMessage?.createdAt ?? conversation.lastMessageAt,
            ),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 6),
          if (conversation.unreadCount > 0)
            Container(
              constraints: const BoxConstraints(minWidth: 20),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
      onTap: () => _openConversation(conversation, targetUser, splitMode),
    );
  }

  String _conversationPreview({
    required Message? message,
    required String draft,
    required int currentUserId,
  }) {
    if (draft.isNotEmpty) return '草稿：$draft';
    if (message == null) return '暂无消息';
    if (message.isFailed) return '发送失败';

    final content = message.content.trim();
    final body = content.isNotEmpty
        ? content
        : message.file != null ||
                message.fileId != null ||
                message.localImagePath?.isNotEmpty == true
            ? '[图片]'
            : '暂无消息';
    return message.senderId == currentUserId ? '你：$body' : body;
  }

  Future<void> _openConversation(
    Conversation conversation,
    User targetUser,
    bool splitMode,
  ) async {
    if (splitMode) {
      setState(() {
        _selectedConversationId = conversation.id;
        _selectedTargetUser = targetUser;
      });
      return;
    }

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
