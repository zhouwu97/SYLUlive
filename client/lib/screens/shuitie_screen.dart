import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/post_provider.dart';
import '../models/announcement.dart' as model;
import '../models/post.dart';
import '../widgets/glass_container.dart';
import '../widgets/post_card.dart';
import 'create_post_screen.dart';
import 'post_detail_screen.dart';
import 'login_screen.dart';

class ShuitieScreen extends StatefulWidget {
  const ShuitieScreen({super.key});

  @override
  State<ShuitieScreen> createState() => _ShuitieScreenState();
}

class _ShuitieScreenState extends State<ShuitieScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _animationController;
  List<model.Announcement> _announcements = [];
  Timer? _autoRefreshTimer;
  bool _wasLoggedIn = false;
  List<Post> _cachedPosts = []; // 本地缓存，防止切换 tab 闪烁

  static const _autoRefreshInterval = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PostProvider>().loadPosts(boardId: 1);
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
      if (mounted) {
        _refresh();
        _loadAnnouncements();
      }
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
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadAnnouncements() async {
    final authProvider = context.read<AuthProvider>();
    try {
      final response = await authProvider.dio.get('/announcements/active');
      if (response.statusCode == 200) {
        final all = (response.data as List)
            .map((e) => model.Announcement.fromJson(e))
            .toList();
        // 过滤掉已取消置顶的
        final dismissed = await _loadDismissedIds();
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
    setState(() {
      _announcements.removeWhere((a) => a.id == id);
    });
  }

  Future<Set<int>> _loadDismissedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('dismissed_announcements') ?? [];
    return list.map((s) => int.tryParse(s) ?? 0).where((i) => i > 0).toSet();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final authProvider = context.watch<AuthProvider>();

    // 检测登录状态切换 → 自动刷新
    if (authProvider.isLoggedIn != _wasLoggedIn) {
      _wasLoggedIn = authProvider.isLoggedIn;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: RefreshIndicator(
        onRefresh: () async {
          await _refresh();
          await _loadAnnouncements();
        },
        child: FadeTransition(
          opacity: CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOut,
          ),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              // 顶部应用栏
              const SliverAppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                pinned: false,
                expandedHeight: 60,
                flexibleSpace: FlexibleSpaceBar(
                  title: Text(
                    '首页',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              // 公告轮播
              if (_announcements.isNotEmpty)
                SliverToBoxAdapter(
                  child: _buildAnnouncementBanner(isDark),
                ),

              // 发布按钮
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: GlassContainer(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    borderRadius: 25,
                    blur: themeProvider.liquidGlass ? 10 : 0,
                    opacity: themeProvider.liquidGlass ? 0.2 : 0,
                    onTap: () {
                      _navigateToCreatePost(context);
                    },
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: Theme.of(context)
                              .primaryColor
                              .withValues(alpha: 0.2),
                          child: const Icon(Icons.edit, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '分享你的想法...',
                          style: TextStyle(
                            color: isDark ? Colors.white60 : Colors.grey[600],
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          Icons.add_circle,
                          color: Theme.of(context).primaryColor,
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 帖子列表
              Consumer<PostProvider>(
                builder: (context, postProvider, child) {
                  var posts = postProvider.posts;
                  // 如果当前为空但缓存有数据，用缓存避免闪烁
                  if (posts.isEmpty && _cachedPosts.isNotEmpty) {
                    posts = _cachedPosts;
                  } else if (posts.isNotEmpty) {
                    _cachedPosts = List.from(posts);
                  }
                  if (postProvider.isLoading && _cachedPosts.isEmpty) {
                    return const SliverFillRemaining(
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (posts.isEmpty) {
                    return SliverFillRemaining(
                      child: _buildEmptyState(isDark, onRetry: _refresh),
                    );
                  }
                  return SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final post = posts[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: PostCard(
                            post: post,
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => PostDetailScreen(
                                      postId: post.id, isMarket: false),
                                ),
                              );
                            },
                          ),
                        );
                      },
                      childCount: posts.length,
                    ),
                  );
                },
              ),

              // 底部留白
              const SliverToBoxAdapter(
                child: SizedBox(height: 100),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    await context.read<PostProvider>().refresh(boardId: 1);
    if (mounted) {
      // 同步缓存，自动清除已被删除的帖子
      final posts = context.read<PostProvider>().posts;
      setState(() => _cachedPosts = List.from(posts));
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
    ).then((_) {
      _refresh();
    });
  }

  Widget _buildAnnouncementBanner(bool isDark) {
    return SizedBox(
      height: 120,
      child: PageView.builder(
        itemCount: _announcements.length,
        controller: PageController(viewportFraction: 0.9),
        itemBuilder: (context, index) {
          final announcement = _announcements[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: GlassContainer(
              padding: const EdgeInsets.all(16),
              borderRadius: 16,
              blur: 10,
              opacity: 0.15,
              gradientColors: isDark
                  ? [Colors.blueGrey[800]!, Colors.blueGrey[900]!]
                  : [Colors.blue[50]!, Colors.blue[100]!],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.campaign,
                        color: Colors.blue[400],
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          announcement.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (announcement.isPinned)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '置顶',
                            style: TextStyle(color: Colors.red, fontSize: 10),
                          ),
                        ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => _dismissAnnouncement(announcement.id),
                        child: Icon(Icons.close,
                            size: 16,
                            color: isDark ? Colors.white30 : Colors.grey[500]),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Text(
                      announcement.content,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white70 : Colors.black87,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(bool isDark, {VoidCallback? onRetry}) {
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
              '暂无帖子',
              style: TextStyle(
                fontSize: 18,
                color: isDark ? Colors.white70 : Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '发布第一条帖子吧！',
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
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
