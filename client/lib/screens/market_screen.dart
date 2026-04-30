import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../models/post.dart';
import '../widgets/post_card.dart';
import '../widgets/glass_container.dart';
import '../providers/theme_provider.dart';
import 'post_detail_screen.dart';
import 'create_post_screen.dart';
import 'login_screen.dart';

class MarketScreen extends StatefulWidget {
  const MarketScreen({super.key});

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<String> _tabs = ['交易', '曝光'];
  String _sortType = 'time';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PostProvider>().loadPosts(boardId: 2, sort: _sortType);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _changeSort(String sort) {
    setState(() {
      _sortType = sort;
    });
    context.read<PostProvider>().refresh(boardId: 2, sort: sort);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelStyle: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
          unselectedLabelStyle: const TextStyle(fontSize: 14),
          tabs: _tabs.map((t) => Tab(text: t)).toList(),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            onSelected: _changeSort,
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'time', child: Text('按时间排序')),
              const PopupMenuItem(value: 'price', child: Text('价格从低到高')),
              const PopupMenuItem(value: 'score', child: Text('综合排序')),
            ],
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildMarketList(isDark),
          _buildExposureList(isDark),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 80),
        child: FloatingActionButton(
          onPressed: () async {
            final authProvider = context.read<AuthProvider>();
            if (!authProvider.isLoggedIn) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请先登录')),
              );
              Navigator.push(
                context,
                PageRouteBuilder(
                  opaque: false,
                  pageBuilder: (_, __, ___) => const LoginScreen(),
                ),
              );
              return;
            }
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CreatePostScreen(
                  boardId: 2,
                  defaultPostType: _tabController.index == 0 ? 'sell' : 'exposure',
                ),
              ),
            );
            if (mounted) {
              context.read<PostProvider>().refresh(boardId: 2, sort: _sortType);
            }
          },
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Widget _buildMarketList(bool isDark) {
    return Consumer<PostProvider>(
      builder: (context, postProvider, child) {
        final allPosts = postProvider.postsFor(2);
        if (postProvider.isLoadingFor(2) && allPosts.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final marketPosts = allPosts
            .where((p) => p.postType == 'sell' || p.postType == 'buy' || p.postType == 'proxy')
            .toList();

        if (marketPosts.isEmpty) {
          return _buildEmptyState('暂无商品', '发布你的第一条商品吧！', isDark);
        }

        return RefreshIndicator(
          onRefresh: () => postProvider.refresh(boardId: 2, sort: _sortType),
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
            itemCount: marketPosts.length,
            itemBuilder: (context, index) {
              final post = marketPosts[index];
              return PostCard(
                post: post,
                showPrice: true,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PostDetailScreen(postId: post.id),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildExposureList(bool isDark) {
    return Consumer<PostProvider>(
      builder: (context, postProvider, child) {
        final allPosts = postProvider.postsFor(2);
        if (postProvider.isLoadingFor(2) && allPosts.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        final exposurePosts = allPosts
            .where((p) => p.postType == 'exposure')
            .toList();

        if (exposurePosts.isEmpty) {
          return _buildEmptyState('暂无曝光', '曝光骗子，维护校园诚信！', isDark);
        }

        return RefreshIndicator(
          onRefresh: () => postProvider.refresh(boardId: 2, sort: _sortType),
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
            itemCount: exposurePosts.length,
            itemBuilder: (context, index) {
              final post = exposurePosts[index];
              return PostCard(
                post: post,
                showWarning: true,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PostDetailScreen(postId: post.id),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(String title, String subtitle, bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(32),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.store_outlined,
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
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white.withOpacity(0.4) : Colors.grey[400],
              ),
            ),
          ],
        ),
      ),
    );
  }
}