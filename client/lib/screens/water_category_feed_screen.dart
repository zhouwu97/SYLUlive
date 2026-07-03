import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/water_post_taxonomy.dart';
import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../widgets/post_card.dart';
import 'create_post_screen.dart';
import 'post_detail_screen.dart';

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
        elevation: 0,
        centerTitle: false,
        title: Text(
          widget.category.label,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _openComposer,
              style: TextButton.styleFrom(
                foregroundColor: widget.category.color,
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              child: Text(widget.category.publishActionText),
            ),
          ),
        ],
      ),
      floatingActionButton: null,
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
          SliverToBoxAdapter(child: _buildEmptyState(isDark))
        else ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
            sliver: SliverList.separated(
              itemCount: posts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 0),
              itemBuilder: (context, index) {
                final post = posts[index];
                return PostCard(
                  post: post,
                  showCategoryBadge: false,
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
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    Color.alphaBlend(
                      category.color.withValues(alpha: 0.22),
                      const Color(0xFF171B24),
                    ),
                    const Color(0xFF171B24),
                  ]
                : [
                    category.color.withValues(alpha: 0.12),
                    Colors.white,
                  ],
          ),
          border: Border.all(
            color: category.color.withValues(alpha: isDark ? 0.22 : 0.15),
          ),
          boxShadow: isDark
              ? null
              : [
                  BoxShadow(
                    color: category.color.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: category.color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(category.icon, color: category.color, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category.label,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                          color:
                              isDark ? Colors.white : const Color(0xFF16181D),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        category.hint,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color:
                              isDark ? Colors.white60 : const Color(0xFF6D7480),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: category.quickTags.map((tag) {
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color:
                        category.color.withValues(alpha: isDark ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '#$tag',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: category.color,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabs(bool isDark) {
    return Container(
      color: isDark ? const Color(0xFF0D1117) : const Color(0xFFF7F8FA),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF171B24) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFEDEFF3),
          ),
        ),
        child: Row(
          children: [
            for (var i = 0; i < _tabs.length; i++)
              Expanded(child: _buildTabButton(isDark, i)),
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(bool isDark, int index) {
    final selected = _currentTabIndex == index;
    final categoryColor = widget.category.color;
    final foreground = selected
        ? categoryColor
        : isDark
            ? Colors.white60
            : const Color(0xFF667085);

    return Padding(
      padding: const EdgeInsets.all(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: () => _changeSort(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? categoryColor.withValues(alpha: isDark ? 0.18 : 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Text(
            _tabs[index].label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final category = widget.category;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 26, 16, 0),
      child: Column(
        children: [
          _buildPrimaryEmptyCard(isDark, category),
          const SizedBox(height: 12),
          _buildStarterQuestionCard(isDark, category),
        ],
      ),
    );
  }

  Widget _buildPrimaryEmptyCard(bool isDark, WaterPostCategory category) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFEDEFF3),
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: category.color.withValues(alpha: 0.12),
            ),
            child: Icon(category.icon, size: 30, color: category.color),
          ),
          const SizedBox(height: 15),
          Text(
            '还没有「${category.label}」相关帖子',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF20232A),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            category.emptyLeadText,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: isDark ? Colors.white54 : const Color(0xFF7B818C),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: FilledButton.icon(
                    onPressed: _openComposer,
                    icon: const Icon(Icons.edit_rounded, size: 17),
                    label: Text(
                      category.publishActionText,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: category.color,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: OutlinedButton.icon(
                    onPressed: _showPostTips,
                    icon: const Icon(Icons.lightbulb_outline_rounded, size: 17),
                    label: const Text(
                      '发帖建议',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: category.color,
                      side: BorderSide(
                        color: category.color.withValues(alpha: 0.30),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStarterQuestionCard(bool isDark, WaterPostCategory category) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171B24) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFEDEFF3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '常见方向',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF20232A),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '不知道发什么，可以从这些开始',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? Colors.white54 : const Color(0xFF7B818C),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: category.starterQuestions.map((question) {
              return Container(
                constraints: const BoxConstraints(maxWidth: 190),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: category.color.withValues(alpha: isDark ? 0.14 : 0.08),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  question,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: category.color,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  void _showPostTips() {
    final category = widget.category;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF171B24) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.18)
                          : const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '可以发什么？',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: isDark ? Colors.white : const Color(0xFF20232A),
                  ),
                ),
                const SizedBox(height: 14),
                for (final question in category.starterQuestions) ...[
                  Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: category.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          question,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF374151),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _openComposer();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: category.color,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: Text(
                      category.publishActionText,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFollowingPlaceholder(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 40, 16, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF171B24) : Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFEDEFF3),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.category.color.withValues(alpha: 0.12),
                ),
                child: Icon(
                  Icons.lock_outline_rounded,
                  size: 30,
                  color: widget.category.color,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '登录后查看关注内容',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF20232A),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '关注你感兴趣的同学后，这里会显示他们在「${widget.category.label}」里的帖子。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.45,
                  color: isDark ? Colors.white54 : const Color(0xFF7B818C),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WaterCategoryTabHeader extends SliverPersistentHeaderDelegate {
  final bool isDark;
  final Widget child;

  _WaterCategoryTabHeader({required this.isDark, required this.child});

  @override
  double get minExtent => 50;

  @override
  double get maxExtent => 50;

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
