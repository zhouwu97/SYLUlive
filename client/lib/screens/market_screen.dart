import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/responsive_util.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../widgets/glass_container.dart';
import '../widgets/market_post_card.dart';
import 'create_post_screen.dart';
import 'login_screen.dart';
import 'market_exposure_screen.dart';
import 'post_detail_screen.dart';

abstract final class AppLayout {
  static const double floatingNavHeight = 64;
  static const double floatingNavBottomMargin = 12;
  static const double fabNavGap = 12;
}

class MarketScreen extends StatefulWidget {
  final List<String>? onlyPostTypes;
  final String? titleOverride;

  const MarketScreen({super.key, this.onlyPostTypes, this.titleOverride});

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
      if (mounted) {
        setState(() {
          _searchQuery = '';
          _searchResults = [];
          _isSearching = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _searchQuery = query;
        _isSearching = true;
      });
    }

    final results = await context.read<PostProvider>().searchPosts(
          boardId: 2,
          sort: _sortType,
          query: query,
          limit: 100,
        );

    if (!mounted || _searchQuery != query) return;

    if (mounted) {
      setState(() {
        _searchResults = results
            .where((post) => _allowedTypes.contains(post.postType))
            .toList();
        _isSearching = false;
      });
    }
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
    if (mounted) {
      setState(() {
        _sortType = sort;
        _isSearching = true;
      });
    }
    await _refreshCurrent();
    if (mounted) {
      setState(() {
        _isSearching = false;
      });
    }
  }

  void _showSortBottomSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              _buildSortOption('time', '最新发布'),
              _buildSortOption('price', '价格从低到高'),
              _buildSortOption('price_desc', '价格从高到低'),
              _buildSortOption('score', '综合排序'),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSortOption(String value, String label) {
    final isSelected = _sortType == value;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).colorScheme.primary;

    return ListTile(
      title: Text(
        label,
        style: TextStyle(
          color: isSelected
              ? primaryColor
              : (isDark ? Colors.white : Colors.black87),
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      trailing: isSelected ? Icon(Icons.check, color: primaryColor) : null,
      onTap: () {
        Navigator.pop(context);
        if (_sortType != value) {
          _changeSort(value);
        }
      },
    );
  }

  List<Post> _buildMarketPosts(List<Post> allPosts) {
    return allPosts.where((p) => _allowedTypes.contains(p.postType)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight + 12;

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF06080D) : const Color(0xFFF4F6FB),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.titleOverride ?? '集市'),
        actions: [
          IconButton(
            icon: Icon(
              themeProvider.marketIsListView
                  ? Icons.grid_view
                  : Icons.view_list,
            ),
            onPressed: () {
              themeProvider.setMarketIsListView(
                !themeProvider.marketIsListView,
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? const [
                          Color(0xFF06080D),
                          Color(0xFF10131A),
                          Color(0xFF06080D),
                        ]
                      : const [
                          Color(0xFFF4F6FB),
                          Color(0xFFEFF3F8),
                          Color(0xFFF8FAFC),
                        ],
                ),
              ),
            ),
          ),
          Consumer<PostProvider>(
            builder: (context, postProvider, child) {
              final allPosts = postProvider.postsFor(2, sort: _sortType);
              final exposurePosts = allPosts
                  .where((post) => post.postType == 'exposure')
                  .toList();
              final marketPosts = _searchQuery.isNotEmpty
                  ? _searchResults
                  : _buildMarketPosts(allPosts);

              if (postProvider.isLoadingFor(2, sort: _sortType) &&
                  allPosts.isEmpty) {
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
                      padding: EdgeInsets.fromLTRB(16, topInset, 16, 16),
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
                          padding: const EdgeInsets.symmetric(horizontal: 16),
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
                        padding: EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            AppLayout.floatingNavHeight +
                                AppLayout.floatingNavBottomMargin +
                                AppLayout.fabNavGap +
                                60),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) =>
                                _buildMarketCard(marketPosts[index], false),
                            childCount: marketPosts.length,
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            AppLayout.floatingNavHeight +
                                AppLayout.floatingNavBottomMargin +
                                AppLayout.fabNavGap +
                                60),
                        sliver: SliverMasonryGrid.extent(
                          maxCrossAxisExtent: 300,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childCount: marketPosts.length,
                          itemBuilder: (context, index) =>
                              _buildMarketCard(marketPosts[index], true),
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
        padding: const EdgeInsets.only(
          bottom: AppLayout.floatingNavHeight +
              AppLayout.floatingNavBottomMargin +
              AppLayout.fabNavGap,
        ),
        child: FloatingActionButton.extended(
          heroTag: 'market_fab',
          label: const Text('发布'),
          icon: const Icon(Icons.add),
          backgroundColor: const Color(0xFF6266D9),
          foregroundColor: Colors.white,
          onPressed: () async {
            final authProvider = context.read<AuthProvider>();
            if (!authProvider.isLoggedIn) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('请先登录')));
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
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const MarketExposureScreen()),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1C1620) : const Color(0xFFFFF7F2),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFFFF6B6B).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.gpp_maybe_outlined,
                color: Color(0xFFFF6B6B),
                size: 20,
              ),
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
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    latest == null
                        ? '查看校园曝光信息'
                        : (latest.title.isNotEmpty
                            ? latest.title
                            : latest.content),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white60 : const Color(0xFF98A2B3),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              exposurePosts.isEmpty ? '暂无新内容' : '${exposurePosts.length} 条',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.white38 : const Color(0xFF98A2B3),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: isDark ? Colors.white38 : const Color(0xFF98A2B3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(bool isDark, int count) {
    final sectionTitle =
        _searchQuery.isNotEmpty ? '搜索结果' : (widget.titleOverride ?? '商品列表');

    String sortLabel = '最新发布';
    switch (_sortType) {
      case 'time':
        sortLabel = '最新发布';
        break;
      case 'price':
        sortLabel = '价格低到高';
        break;
      case 'price_desc':
        sortLabel = '价格高到低';
        break;
      case 'score':
        sortLabel = '综合排序';
        break;
    }

    return Row(
      children: [
        Text(
          sectionTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : const Color(0xFF1D2129),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '· 已加载 $count 件',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? Colors.white38 : const Color(0xFF98A2B3),
          ),
        ),
        const Spacer(),
        if (widget.titleOverride != '失物招领')
          GestureDetector(
            onTap: _showSortBottomSheet,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sortLabel,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white70 : const Color(0xFF667085),
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down,
                  size: 16,
                  color: isDark ? Colors.white70 : const Color(0xFF667085),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildMarketCard(Post post, [bool inGrid = false]) {
    return Padding(
      padding: EdgeInsets.only(bottom: inGrid ? 0 : 12),
      child: MarketPostCard(
        post: post,
        compact: inGrid,
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
