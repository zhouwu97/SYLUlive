import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/announcement.dart' as model;
import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/post_card.dart';
import 'announcement_screen.dart';
import 'create_post_screen.dart';
import 'login_screen.dart';
import 'market_screen.dart';
import 'post_detail_screen.dart';

class ShuitieScreen extends StatefulWidget {
  const ShuitieScreen({super.key});

  @override
  State<ShuitieScreen> createState() => _ShuitieScreenState();
}

class _ShuitieScreenState extends State<ShuitieScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _animationController;
  final TextEditingController _searchController = TextEditingController();
  Timer? _autoRefreshTimer;
  Timer? _searchDebounce;
  List<model.Announcement> _announcements = [];
  bool _wasLoggedIn = false;
  List<Post> _cachedPosts = [];
  String _feedMode = 'new';
  String _searchQuery = '';
  bool _isSearching = false;
  List<Post> _searchResults = [];

  static const _autoRefreshInterval = Duration(seconds: 60);

  String get _currentSort => _feedMode == 'hot' ? 'score' : 'time';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PostProvider>().loadPosts(boardId: 1, sort: _currentSort);
      context.read<PostProvider>().loadPosts(boardId: 2, sort: 'time');
      _loadAnnouncements();
      _animationController.forward();
      _startAutoRefresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _loadAnnouncements();
      _startAutoRefresh();
    } else if (state == AppLifecycleState.paused) {
      _stopAutoRefresh();
    }
  }

  void _startAutoRefresh() {
    _stopAutoRefresh();
    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (!mounted) return;
      _refresh();
      _loadAnnouncements();
    });
  }

  void _stopAutoRefresh() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAutoRefresh();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadAnnouncements() async {
    final authProvider = context.read<AuthProvider>();
    try {
      final response = await authProvider.dio.get('/announcements');
      if (response.statusCode == 200) {
        final all = (response.data as List)
            .map((e) => model.Announcement.fromJson(e))
            .toList();
        final dismissed = await _loadDismissedIds();
        if (!mounted) return;
        setState(() {
          _announcements = all.where((a) => !dismissed.contains(a.id)).toList();
        });
      }
    } catch (e) {
      debugPrint('加载公告失败: $e');
    }
  }

  Future<void> _dismissAnnouncement(int id) async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'dismissed_announcements';
    final list = prefs.getStringList(key) ?? [];
    if (!list.contains(id.toString())) {
      list.add(id.toString());
      await prefs.setStringList(key, list);
    }
    if (!mounted) return;
    setState(() {
      _announcements.removeWhere((a) => a.id == id);
    });
  }

  Future<Set<int>> _loadDismissedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('dismissed_announcements') ?? [];
    return list.map((s) => int.tryParse(s) ?? 0).where((i) => i > 0).toSet();
  }

  Future<void> _runSearch(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _searchQuery = '';
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _searchQuery = query;
      _isSearching = true;
    });

    final results = await context.read<PostProvider>().searchPosts(
          boardId: 1,
          sort: _currentSort,
          query: query,
          limit: 100,
        );

    if (!mounted || _searchQuery != query) return;
    final keyword = query.toLowerCase();
    setState(() {
      _searchResults = results
          .where(
            (post) => post.title.trim().toLowerCase().contains(keyword),
          )
          .toList();
      _isSearching = false;
    });
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 260), () {
      _runSearch(value);
    });
  }

  Future<void> _changeFeedMode(String mode) async {
    if (_feedMode == mode) return;
    setState(() => _feedMode = mode);
    await _refresh();
  }

  List<Post> _resolveVisiblePosts(List<Post> posts) {
    if (_searchQuery.isNotEmpty) return _searchResults;
    if (_feedMode == 'new') {
      final now = DateTime.now();
      final recent = posts
          .where((post) => now.difference(post.createdAt).inDays < 3)
          .toList();
      if (recent.isNotEmpty) return recent;
      return posts.take(12).toList();
    }
    return posts;
  }

  Future<void> _refresh() async {
    final postProvider = context.read<PostProvider>();
    await postProvider.refresh(boardId: 1, sort: _currentSort);
    await postProvider.refresh(boardId: 2, sort: 'time');
    if (!mounted) return;
    final posts = postProvider.posts;
    setState(() {
      _cachedPosts = List.from(posts);
    });
    if (_searchQuery.isNotEmpty) {
      await _runSearch(_searchQuery);
    }
  }

  void _navigateToCreatePost(BuildContext context) {
    final authProvider = context.read<AuthProvider>();
    if (!authProvider.isLoggedIn) {
      Navigator.push(
        context,
        PageRouteBuilder(
          opaque: false,
          pageBuilder: (_, __, ___) => const LoginScreen(),
        ),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const CreatePostScreen(boardId: 1),
      ),
    ).then((_) => _refresh());
  }

  void _showComingSoon(String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label 功能开发中')),
    );
  }

  Future<void> _handleFeedSwipe(DragEndDetails details) async {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 320) return;
    const modes = ['new', 'all', 'hot'];
    final currentIndex = modes.indexOf(_feedMode);
    if (currentIndex < 0) return;
    final nextIndex = velocity < 0
        ? (currentIndex + 1).clamp(0, modes.length - 1)
        : (currentIndex - 1).clamp(0, modes.length - 1);
    if (nextIndex != currentIndex) {
      await _changeFeedMode(modes[nextIndex]);
    }
  }

  Widget _buildDefaultBg(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/images/morenbeijing.jpeg',
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
          ),
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.32)
              : Colors.white.withValues(alpha: 0.22),
        ),
      ],
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    final path = themeProvider.backgroundImage;
    if (themeProvider.hasBackground && path != null && path.isNotEmpty) {
      final isAsset = !path.startsWith('http') && !path.startsWith('/');
      return Stack(
        fit: StackFit.expand,
        children: [
          isAsset
              ? Image.asset(
                  'assets/images/$path',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                )
              : path.startsWith('/')
                  ? Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                    )
                  : Image.network(
                      path,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildDefaultBg(isDark),
                    ),
          Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.32)
                : Colors.white.withValues(alpha: 0.18),
          ),
        ],
      );
    }
    return _buildDefaultBg(isDark);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final authProvider = context.watch<AuthProvider>();
    final themeProvider = context.watch<ThemeProvider>();

    if (authProvider.isLoggedIn != _wasLoggedIn) {
      _wasLoggedIn = authProvider.isLoggedIn;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(child: _buildBackground(themeProvider, isDark)),
          RefreshIndicator(
            onRefresh: () async {
              await _refresh();
              await _loadAnnouncements();
            },
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: _animationController,
                curve: Curves.easeOut,
              ),
              child: Consumer<PostProvider>(
                builder: (context, postProvider, child) {
                  var posts = postProvider.posts;
                  if (posts.isEmpty && _cachedPosts.isNotEmpty) {
                    posts = _cachedPosts;
                  } else if (posts.isNotEmpty) {
                    _cachedPosts = List.from(posts);
                  }

                  final visiblePosts = _resolveVisiblePosts(posts);
                  final lostFoundPosts = postProvider
                      .postsFor(2)
                      .where((post) =>
                          post.postType == 'lost' || post.postType == 'found')
                      .toList();

                  return GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragEnd: _handleFeedSwipe,
                    child: CustomScrollView(
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: [
                        const SliverToBoxAdapter(child: SizedBox(height: 18)),
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                          sliver: SliverList(
                            delegate: SliverChildListDelegate(
                              [
                                const SizedBox(height: 12),
                                _buildFeedModeBar(isDark),
                                const SizedBox(height: 12),
                                _buildSearchBar(isDark),
                                const SizedBox(height: 12),
                                _buildAnnouncementPanel(isDark),
                                const SizedBox(height: 10),
                                _buildQuickActions(isDark, lostFoundPosts),
                                const SizedBox(height: 12),
                                _buildFeedHeader(isDark, visiblePosts.length),
                                const SizedBox(height: 10),
                              ],
                            ),
                          ),
                        ),
                        if (postProvider.isLoading && _cachedPosts.isEmpty)
                          const SliverFillRemaining(
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (_isSearching)
                          const SliverFillRemaining(
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (visiblePosts.isEmpty)
                          SliverFillRemaining(
                            child: _buildEmptyState(
                              isDark,
                              title:
                                  _searchQuery.isNotEmpty ? '没有找到匹配帖子' : '暂无帖子',
                              subtitle: _searchQuery.isNotEmpty
                                  ? '目前只按标题搜索，换个标题关键词试试'
                                  : '发布第一条帖子吧',
                              onRetry: _refresh,
                            ),
                          )
                        else
                          SliverList(
                            delegate: SliverChildBuilderDelegate(
                              (context, index) {
                                final post = visiblePosts[index];
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  child: PostCard(
                                    post: post,
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => PostDetailScreen(
                                            postId: post.id,
                                            isMarket: false,
                                            initialPost: post,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                );
                              },
                              childCount: visiblePosts.length,
                            ),
                          ),
                        const SliverToBoxAdapter(child: SizedBox(height: 100)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: GlassContainer(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            borderRadius: 18,
            blur: 12,
            opacity: 0.18,
            backgroundColor:
                isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
            borderColor: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.72),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onSubmitted: _runSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: '搜索帖子标题',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _runSearch('');
                          setState(() {});
                        },
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        GlassContainer(
          width: 54,
          height: 54,
          borderRadius: 18,
          blur: 12,
          opacity: 0.18,
          backgroundColor:
              isDark ? const Color(0xA3251B3A) : const Color(0xFFEFE8FF),
          onTap: () => _navigateToCreatePost(context),
          child: const Icon(
            Icons.add_rounded,
            color: Color(0xFF6D5EF9),
            size: 26,
          ),
        ),
      ],
    );
  }

  Widget _buildQuickActions(bool isDark, List<Post> lostFoundPosts) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _buildUtilityCard(
            isDark: isDark,
            backgroundColor:
                isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
            iconBg: const Color(0xFF16A34A).withValues(alpha: 0.14),
            icon: Icons.task_alt_rounded,
            iconColor: const Color(0xFF16A34A),
            title: '签到',
            subtitle: '每日一次',
            onTap: () => _showComingSoon('签到'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildUtilityCard(
            isDark: isDark,
            backgroundColor:
                isDark ? const Color(0x99212A36) : const Color(0xD9EEF8F2),
            iconBg: const Color(0xFF0EA5A4).withValues(alpha: 0.14),
            icon: Icons.luggage_outlined,
            iconColor: const Color(0xFF0EA5A4),
            title: '失物招领',
            subtitle:
                lostFoundPosts.isEmpty ? '查看线索' : '${lostFoundPosts.length} 条',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const MarketScreen(
                  onlyPostTypes: ['lost', 'found'],
                  titleOverride: '失物招领',
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildUtilityCard(
            isDark: isDark,
            backgroundColor:
                isDark ? const Color(0x99211D2F) : const Color(0xD9FFF2E8),
            iconBg: const Color(0xFFF97316).withValues(alpha: 0.14),
            icon: Icons.handyman_outlined,
            iconColor: const Color(0xFFF97316),
            title: '工具箱',
            subtitle: '开发中',
            onTap: () => _showComingSoon('工具箱'),
          ),
        ),
      ],
    );
  }

  Widget _buildUtilityCard({
    required bool isDark,
    required Color backgroundColor,
    required Color iconBg,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GlassContainer(
      height: 78,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      borderRadius: 18,
      blur: 12,
      opacity: 0.18,
      backgroundColor: backgroundColor,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 15),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9.5,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnnouncementPanel(bool isDark) {
    final latest = _announcements.isNotEmpty ? _announcements.first : null;
    return GlassContainer(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AnnouncementScreen()),
      ),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      borderRadius: 22,
      blur: 12,
      opacity: 0.18,
      backgroundColor:
          isDark ? const Color(0x99202A43) : const Color(0xD9EEF6FF),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.campaign_outlined,
                    color: Color(0xFF3B82F6), size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '系统公告',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    Text(
                      latest == null ? '当前没有新的系统消息' : '最新通知与校园消息',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white54 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              if (_announcements.isNotEmpty)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${_announcements.length} 条',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF3B82F6),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (latest == null)
            Text(
              '当前没有新的系统公告',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            )
          else ...[
            Text(
              latest.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              latest.content,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (latest.isPinned)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '置顶公告',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.red,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                const Spacer(),
                GestureDetector(
                  onTap: () => _dismissAnnouncement(latest.id),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '收起',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white60 : Colors.black54,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFeedModeBar(bool isDark) {
    const items = [
      ('new', '新帖子'),
      ('all', '综合'),
      ('hot', '热门'),
    ];
    return GlassContainer(
      padding: const EdgeInsets.all(4),
      borderRadius: 18,
      blur: 10,
      opacity: 0.16,
      backgroundColor:
          isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
      child: Row(
        children: items.map((item) {
          final active = _feedMode == item.$1;
          return Expanded(
            child: GestureDetector(
              onTap: () => _changeFeedMode(item.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                decoration: BoxDecoration(
                  color: active
                      ? Theme.of(context).primaryColor.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  item.$2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active
                        ? Theme.of(context).primaryColor
                        : (isDark ? Colors.white70 : Colors.black54),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildFeedHeader(bool isDark, int count) {
    final title = _searchQuery.isNotEmpty
        ? '搜索结果'
        : (_feedMode == 'hot'
            ? '热门讨论'
            : _feedMode == 'all'
                ? '综合帖子'
                : '最新动态');
    final subtitle = _searchQuery.isNotEmpty ? '仅匹配帖子标题' : '$count 条内容';
    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEmptyState(
    bool isDark, {
    required String title,
    required String subtitle,
    VoidCallback? onRetry,
  }) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(24),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: isDark ? Colors.white60 : Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                color: isDark ? Colors.white70 : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.4)
                    : Colors.grey[400],
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新试试'),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
