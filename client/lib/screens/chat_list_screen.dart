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
import '../widgets/swipe_to_exit.dart';
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
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

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
    _searchController.dispose();
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
      return SwipeToExit(child: _buildLoginRequiredScaffold());
    }

    final currentUserId = auth.user?.id ?? 0;
    final provider = context.watch<MessageProvider>();
    final isWide = MediaQuery.sizeOf(context).width >= 720;

    if (isWide) {
      _syncWideSelection(provider, currentUserId);
      return SwipeToExit(child: _buildWideLayout(provider, currentUserId));
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SwipeToExit(
      child: Scaffold(
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
            resizeToAvoidBottomInset: false,
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
    final conversations = _filteredConversations(provider, currentUserId);
    return Column(
      children: [
        _buildConversationSearchField(),
        Expanded(
          child: _buildConversationContent(
            provider,
            conversations,
            currentUserId,
            splitMode: splitMode,
          ),
        ),
      ],
    );
  }

  Widget _buildConversationSearchField() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: SizedBox(
        height: 42,
        child: TextField(
          key: const ValueKey('chat-conversation-search'),
          controller: _searchController,
          onChanged: (value) => setState(() => _searchQuery = value),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索联系人或消息',
            isDense: true,
            filled: true,
            fillColor: isDark
                ? const Color(0xFF242A35)
                : const Color(0xFFF1F2F6),
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: _searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: '清除搜索',
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );
  }

  List<Conversation> _filteredConversations(
    MessageProvider provider,
    int currentUserId,
  ) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return provider.conversations;
    return provider.conversations.where((conversation) {
      final targetUser = conversation.getOtherUser(currentUserId);
      if (targetUser == null) return false;
      final message = _latestConversationMessage(provider, conversation);
      final content = message?.content.trim() ?? '';
      final searchText = [
        targetUser.nickname,
        content,
        if (message?.isSticker == true) '表情',
        if (message?.file != null || message?.fileId != null) '图片',
      ].join('\n').toLowerCase();
      return searchText.contains(query);
    }).toList(growable: false);
  }

  Message? _latestConversationMessage(
    MessageProvider provider,
    Conversation conversation,
  ) {
    final cachedMessage =
        provider.latestCachedMessageForConversation(conversation.id);
    final serverMessage = conversation.lastMessage;
    if (cachedMessage == null) return serverMessage;
    if (serverMessage == null ||
        !cachedMessage.createdAt.isBefore(serverMessage.createdAt)) {
      return cachedMessage;
    }
    return serverMessage;
  }

  Widget _buildConversationContent(
    MessageProvider provider,
    List<Conversation> conversations,
    int currentUserId, {
    required bool splitMode,
  }) {
    if (provider.conversationLoading && provider.conversations.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Center(child: CircularProgressIndicator()),
        ],
      );
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

    if (provider.conversations.isEmpty || conversations.isEmpty) {
      final hasQuery = _searchQuery.trim().isNotEmpty;
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.24),
          Icon(
            hasQuery ? Icons.search_off_rounded : Icons.forum_outlined,
            size: 64,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              hasQuery ? '没有匹配的会话' : '暂无私信\n可以从其他用户主页发起聊天',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      itemCount: conversations.length,
      itemBuilder: (context, index) {
        final conversation = conversations[index];
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
    final draftStickerId = provider.draftStickerFor(targetUser.id);
    final hasDraft = draft.isNotEmpty || draftStickerId != null;
    final draftBody = [
      if (draft.isNotEmpty) draft,
      if (draftStickerId != null) '[表情]',
    ].join(' ');
    final preview = hasDraft
        ? draftBody
        : _conversationPreview(
            message: lastMessage,
            draft: draft,
            draftStickerId: draftStickerId,
            currentUserId: currentUserId,
          );
    final previewIsAlert = !hasDraft && lastMessage?.isFailed == true;
    final selected = splitMode && _selectedConversationId == conversation.id;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final muted = isDark ? Colors.white60 : const Color(0xFF6B7280);
    final nickname = targetUser.nickname.isEmpty
        ? '用户${targetUser.id}'
        : targetUser.nickname;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openConversation(conversation, targetUser, splitMode),
          child: SizedBox(
            height: 72,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  CachedAvatar(
                    imageUrl: targetUser.avatar.isEmpty
                        ? null
                        : ApiConstants.fullUrl(targetUser.avatar),
                    radius: 25,
                    fallbackText: nickname,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nickname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (hasDraft)
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '草稿：',
                                  style: TextStyle(color: Colors.red.shade600),
                                ),
                                TextSpan(
                                  text: preview,
                                  style: TextStyle(color: muted),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        else
                          Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: previewIsAlert
                                  ? Colors.red.shade600
                                  : muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 58,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _formatConversationTime(
                            draft.isNotEmpty
                                ? conversation.lastMessageAt
                                : lastMessage?.createdAt ??
                                    conversation.lastMessageAt,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                        const SizedBox(height: 6),
                        if (conversation.unreadCount > 0)
                          Container(
                            constraints: const BoxConstraints(minWidth: 20),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              conversation.unreadCount > 99
                                  ? '99+'
                                  : '${conversation.unreadCount}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
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
    );
  }

  String _conversationPreview({
    required Message? message,
    required String draft,
    required String? draftStickerId,
    required int currentUserId,
  }) {
    if (draft.isNotEmpty || draftStickerId != null) {
      final draftBody = [
        if (draft.isNotEmpty) draft,
        if (draftStickerId != null) '[表情]',
      ].join(' ');
      return '草稿：$draftBody';
    }
    if (message == null) return '暂无消息';
    if (message.isFailed) return '发送失败';

    final content = message.content.trim();
    final body = content.isNotEmpty
        ? content
        : message.isSticker
            ? '[表情]'
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
