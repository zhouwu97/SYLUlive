import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/water_post_taxonomy.dart';
import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../widgets/post_card.dart';
import 'create_post_screen.dart';
import 'post_detail_screen.dart';

class WaterCategoryFeedRoute extends StatelessWidget {
  final WaterPostCategory category;

  const WaterCategoryFeedRoute({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => PostProvider(
        context.read<AuthProvider>().dio,
        enableCache: false,
      ),
      child: WaterCategoryFeedScreen(category: category),
    );
  }
}

class FeedTab {
  final String label;
  final String sort;

  const FeedTab({required this.label, required this.sort});
}

class WaterCategoryFeedScreen extends StatefulWidget {
  final WaterPostCategory category;

  const WaterCategoryFeedScreen({super.key, required this.category});

  @override
  State<WaterCategoryFeedScreen> createState() =>
      _WaterCategoryFeedScreenState();
}

class _WaterCategoryFeedScreenState extends State<WaterCategoryFeedScreen> {
  static const _tabs = [
    FeedTab(label: '最新', sort: 'time'),
    FeedTab(label: '综合', sort: 'all'),
    FeedTab(label: '精华', sort: 'featured'),
    FeedTab(label: '关注', sort: 'following'),
  ];

  final _scrollController = ScrollController();
  String _currentSort = 'all';
  int _currentTabIndex = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool get _isFollowingTab => _currentSort == 'following';

  Future<void> _load() {
    if (_isFollowingTab && !context.read<AuthProvider>().isLoggedIn) {
      return Future.value();
    }
    return context.read<PostProvider>().loadPosts(
          boardId: 1,
          sort: _currentSort,
          type: widget.category.value,
        );
  }

  Future<void> _refresh() {
    if (_isFollowingTab && !context.read<AuthProvider>().isLoggedIn) {
      return Future.value();
    }
    return context.read<PostProvider>().refresh(
          boardId: 1,
          sort: _currentSort,
          type: widget.category.value,
        );
  }

  Future<void> _loadMore() {
    if (_isFollowingTab && !context.read<AuthProvider>().isLoggedIn) {
      return Future.value();
    }
    return context.read<PostProvider>().loadPosts(
          boardId: 1,
          sort: _currentSort,
          type: widget.category.value,
        );
  }

  Future<void> _changeSort(int index) async {
    if (index == _currentTabIndex) return;
    setState(() {
      _currentTabIndex = index;
      _currentSort = _tabs[index].sort;
    });
    await _load();
  }

  Future<void> _openComposer() async {
    final published = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(
          boardId: 1,
          defaultPostType: widget.category.value,
        ),
      ),
    );
    if (published == true && mounted) {
      await _refresh();
    }
  }

  Future<void> _openPost(Post post) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PostDetailScreen(
          postId: post.id,
          initialPost: post,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final background =
        isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA);

    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: isDark ? const Color(0xFF0D1117) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0.5,
        centerTitle: false,
        title: Text(widget.category.label),
        actions: [
          IconButton(
            tooltip: '发布',
            onPressed: _openComposer,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openComposer,
        child: const Icon(Icons.edit_rounded),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification.metrics.pixels >=
                notification.metrics.maxScrollExtent - 360) {
              final provider = context.read<PostProvider>();
              final isLoading = provider.isLoadingFor(
                1,
                sort: _currentSort,
                type: widget.category.value,
              );
              final hasMore = provider.hasMoreFor(
                1,
                sort: _currentSort,
                type: widget.category.value,
              );
              if (!isLoading && hasMore) {
                _loadMore();
              }
            }
            return false;
          },
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Selector<
                  PostProvider,
                  ({
                    List<Post> posts,
                    bool isLoading,
                    bool hasMore,
                    int revision
                  })>(
                selector: (context, provider) => (
                  posts: provider.postsFor(
                    1,
                    sort: _currentSort,
                    type: widget.category.value,
                  ),
                  isLoading: provider.isLoadingFor(
                    1,
                    sort: _currentSort,
                    type: widget.category.value,
                  ),
                  hasMore: provider.hasMoreFor(
                    1,
                    sort: _currentSort,
                    type: widget.category.value,
                  ),
                  revision: provider.revisionFor(
                    1,
                    sort: _currentSort,
                    type: widget.category.value,
                  ),
                ),
                builder: (context, data, _) => _buildScrollContent(
                  isDark,
                  data.posts,
                  data.isLoading,
                  data.hasMore,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScrollContent(
    bool isDark,
    List<Post> posts,
    bool isLoading,
    bool hasMore,
  ) {
    final showLoginPlaceholder =
        _isFollowingTab && !context.read<AuthProvider>().isLoggedIn;

    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(child: _buildHeader(isDark)),
        SliverPersistentHeader(
          pinned: true,
          delegate: _WaterCategoryTabHeader(
            isDark: isDark,
            child: _buildTabs(isDark),
          ),
        ),
        if (showLoginPlaceholder)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildFollowingPlaceholder(isDark),
          )
        else if (isLoading && posts.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (posts.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _buildEmptyState(isDark),
          )
        else ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            sliver: SliverList.separated(
              itemCount: posts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 0),
              itemBuilder: (context, index) {
                final post = posts[index];
                return PostCard(
                  post: post,
                  onTap: () => _openPost(post),
                );
              },
            ),
          ),
          if (isLoading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 96),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (!hasMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 96),
                child: Center(
                  child: Text(
                    '已经到底了',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : const Color(0xFF9AA0A6),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildHeader(bool isDark) {
    final category = widget.category;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF171B24) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFEDEFF3),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: category.color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(category.icon, color: category.color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category.label,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : const Color(0xFF16181D),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    category.hint,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white60 : const Color(0xFF6D7480),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    category.actionHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : const Color(0xFF8A919D),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF171B24) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFEDEFF3),
          ),
        ),
        child: Row(
          children: [
            for (var i = 0; i < _tabs.length; i++)
              Expanded(
                child: _buildTabButton(isDark, i),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(bool isDark, int index) {
    final selected = _currentTabIndex == index;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _changeSort(index),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _tabs[index].label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : isDark
                        ? Colors.white60
                        : const Color(0xFF626A75),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: selected ? 18 : 0,
              height: 2,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final category = widget.category;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(category.icon, size: 42, color: category.color),
          const SizedBox(height: 16),
          Text(
            category.emptyTitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : const Color(0xFF20232A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            category.emptyDescription,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: isDark ? Colors.white54 : const Color(0xFF7B818C),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _openComposer,
            icon: const Icon(Icons.edit_rounded, size: 18),
            label: const Text('发布第一条'),
          ),
        ],
      ),
    );
  }

  Widget _buildFollowingPlaceholder(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 42,
            color: isDark ? Colors.white38 : const Color(0xFF9AA0A6),
          ),
          const SizedBox(height: 16),
          Text(
            '登录后查看关注内容',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : const Color(0xFF20232A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '关注 tab 会显示你关注用户在「${widget.category.label}」中的帖子。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: isDark ? Colors.white54 : const Color(0xFF7B818C),
            ),
          ),
        ],
      ),
    );
  }
}

class _WaterCategoryTabHeader extends SliverPersistentHeaderDelegate {
  final bool isDark;
  final Widget child;

  _WaterCategoryTabHeader({required this.isDark, required this.child});

  @override
  double get minExtent => 52;

  @override
  double get maxExtent => 52;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _WaterCategoryTabHeader oldDelegate) {
    return oldDelegate.isDark != isDark || oldDelegate.child != child;
  }
}
