import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/responsive_util.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../widgets/glass_container.dart';
import '../widgets/post_card.dart';
import 'create_post_screen.dart';
import 'login_screen.dart';
import 'market_exposure_screen.dart';
import 'post_detail_screen.dart';

class MarketScreen extends StatefulWidget {
  final List<String>? onlyPostTypes;
  final String? titleOverride;

  const MarketScreen({
    super.key,
    this.onlyPostTypes,
    this.titleOverride,
  });

  @override
  State<MarketScreen> createState() => _MarketScreenState();
}

class _MarketScreenState extends State<MarketScreen> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _sortType = 'time';
  String _searchQuery = '';
  bool _isSearching = false;
  List<Post> _searchResults = [];

  static const _marketPostTypes = ['sell', 'buy', 'proxy', 'lost', 'found'];

  List<String> get _allowedTypes =>
      widget.onlyPostTypes == null || widget.onlyPostTypes!.isEmpty
          ? _marketPostTypes
          : widget.onlyPostTypes!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PostProvider>().loadPosts(boardId: 2, sort: _sortType);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String raw) async {
    final query = raw.trim();
    if (!mounted) return;

    if (query.isEmpty) {
      if (mounted) setState(() {
        _searchQuery = '';
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    if (mounted) setState(() {
      _searchQuery = query;
      _isSearching = true;
    });

    final results = await context.read<PostProvider>().searchPosts(
          boardId: 2,
          sort: _sortType,
          query: query,
          limit: 100,
        );

    if (!mounted || _searchQuery != query) return;

    if (mounted) setState(() {
      _searchResults = results
          .where((post) => _allowedTypes.contains(post.postType))
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

  Future<void> _refreshCurrent() async {
    await context.read<PostProvider>().refresh(boardId: 2, sort: _sortType);
    if (_searchQuery.isNotEmpty) {
      await _runSearch(_searchQuery);
    }
  }

  void _changeSort(String sort) async {
    if (mounted) setState(() {
      _sortType = sort;
      _isSearching = true;
    });
    await _refreshCurrent();
    if (mounted) {
      setState(() {
        _isSearching = false;
      });
    }
  }

  List<Post> _buildMarketPosts(List<Post> allPosts) {
    return allPosts.where((p) => _allowedTypes.contains(p.postType)).toList();
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
              ? Colors.black.withValues(alpha: 0.34)
              : Colors.white.withValues(alpha: 0.20),
        ),
      ],
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    final path = themeProvider.getBackgroundImageFor(context);
    if (themeProvider.isBackgroundVisible && path != null && path.isNotEmpty) {
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
                ? Colors.black.withValues(alpha: 0.34)
                : Colors.white.withValues(alpha: 0.20),
          ),
        ],
      );
    }
    return _buildDefaultBg(isDark);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight + 12;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.titleOverride ?? '集市'),
        actions: [
          IconButton(
            icon: Icon(themeProvider.marketIsListView ? Icons.grid_view : Icons.view_list),
            onPressed: () {
              themeProvider.setMarketIsListView(!themeProvider.marketIsListView);
            },
          ),
          if (widget.titleOverride != '失物招领')
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              onSelected: _changeSort,
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'time', child: Text('按时间排序')),
                PopupMenuItem(
                  value: _sortType == 'price' ? 'price_desc' : 'price',
                  child: Text(_sortType == 'price' ? '价格从高到低' : '价格从低到高'),
                ),
                const PopupMenuItem(value: 'score', child: Text('综合排序')),
              ],
            ),
        ],
      ),
      body: Stack(
        children: [
          Consumer<PostProvider>(
            builder: (context, postProvider, child) {
              final allPosts = postProvider.postsFor(2);
              final exposurePosts = allPosts
                  .where((post) => post.postType == 'exposure')
                  .toList();
              final marketPosts = _searchQuery.isNotEmpty
                  ? _searchResults
                  : _buildMarketPosts(allPosts);

              if (postProvider.isLoadingFor(2) && allPosts.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }

              return RefreshIndicator(
                onRefresh: _refreshCurrent,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(12, topInset, 12, 12),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          _buildSearchBar(isDark),
                          if (widget.onlyPostTypes == null) ...[
                            const SizedBox(height: 12),
                            _buildExposureEntry(isDark, exposurePosts),
                            const SizedBox(height: 16),
                          ] else
                            const SizedBox(height: 16),
                          _buildSectionHeader(isDark, marketPosts.length),
                        ]),
                      ),
                    ),
                    if (_isSearching)
                      const SliverFillRemaining(
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (marketPosts.isEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: _buildEmptyState(
                            isDark,
                            _searchQuery.isNotEmpty ? '没有找到匹配内容' : '暂无内容',
                            _searchQuery.isNotEmpty
                                ? '换个关键词试试'
                                : (widget.titleOverride == '失物招领'
                                    ? '发布一条失物或招领信息吧'
                                    : '发布你的第一条商品吧'),
                          ),
                        ),
                      )
                    else if (themeProvider.marketIsListView)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => _buildMarketCard(marketPosts[index], false),
                            childCount: marketPosts.length,
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
                        sliver: SliverMasonryGrid.extent(
                          maxCrossAxisExtent: 300,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childCount: marketPosts.length,
                          itemBuilder: (context, index) => _buildMarketCard(marketPosts[index], true),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
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
                  defaultPostType: widget.onlyPostTypes != null &&
                          widget.onlyPostTypes!.contains('lost')
                      ? 'lost'
                      : 'sell',
                  allowedPostTypes: widget.onlyPostTypes,
                ),
              ),
            );
            if (mounted) {
              await _refreshCurrent();
            }
          },
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return GlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      borderRadius: 12,
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
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          hintText: '搜索商品名称，支持模糊匹配',
          hintStyle: const TextStyle(fontSize: 14),
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    _searchController.clear();
                    _runSearch('');
                    setState(() {});
                  },
                ),
        ),
      ),
    );
  }

  Widget _buildExposureEntry(bool isDark, List<Post> exposurePosts) {
    final latest = exposurePosts.isNotEmpty ? exposurePosts.first : null;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const MarketExposureScreen()),
      ),
      child: GlassContainer(
        padding: const EdgeInsets.all(14),
      borderRadius: 50,
      blur: 12,
        opacity: 0.18,
        backgroundColor:
            isDark ? const Color(0xA31C1620) : const Color(0xD9FFF4F2),
        borderColor: isDark ? const Color(0x66FF8A80) : const Color(0x88FFD5D0),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFFF6B6B).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.gpp_maybe_outlined,
                  color: Color(0xFFFF6B6B), size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '曝光台',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFFFF6B6B).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${exposurePosts.length} 条',
                          style: const TextStyle(
                            color: Color(0xFFFF6B6B),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    latest == null
                        ? '单独查看曝光内容，不打断正常逛集市'
                        : (latest.title.isNotEmpty
                            ? latest.title
                            : latest.content),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white60 : Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right_rounded,
              color: isDark ? Colors.white38 : Colors.grey[500],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(bool isDark, int count) {
    final title =
        _searchQuery.isNotEmpty ? '搜索结果' : (widget.titleOverride ?? '商品列表');
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white38 : Colors.grey[600],
          ),
        ),
      ],
    );
  }

  Widget _buildMarketCard(Post post, [bool inGrid = false]) {
    return Padding(
      padding: EdgeInsets.only(bottom: inGrid ? 0 : 12),
      child: PostCard(
        post: post,
        showPrice: true,
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PostDetailScreen(
                postId: post.id,
                isMarket: true,
                initialPost: post,
                isDesktopSplitMode: ResponsiveUtil.isDesktop(context),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(bool isDark, String title, String subtitle) {
    return GlassContainer(
      padding: const EdgeInsets.all(20),
      borderRadius: 12,
      blur: 12,
      opacity: 0.18,
      backgroundColor:
          isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
      borderColor: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.white.withValues(alpha: 0.72),
      child: Column(
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 42,
            color: isDark ? Colors.white38 : Colors.grey[500],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.black87,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.white38 : Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }
}
