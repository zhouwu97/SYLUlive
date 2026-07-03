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
  String _typeFilter = 'all';

  static const _marketPostTypes = ['sell', 'buy', 'proxy', 'lost', 'found'];

  List<String> get _allowedTypes =>
      widget.onlyPostTypes == null || widget.onlyPostTypes!.isEmpty
          ? _marketPostTypes
          : widget.onlyPostTypes!;

  int get _activeFilterCount => _typeFilter == 'all' ? 0 : 1;

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

  String _typeLabel(String value) {
    switch (value) {
      case 'sell':
        return '出售';
      case 'buy':
        return '求购';
      case 'proxy':
        return '代取';
      case 'lost':
        return '寻物';
      case 'found':
        return '招领';
      case 'all':
      default:
        return '全部';
    }
  }

  void _changeTypeFilter(String value) {
    if (_typeFilter == value) return;
    setState(() {
      _typeFilter = value;
    });
  }

  List<Post> _applyLocalTypeFilter(List<Post> posts) {
    return posts.where((post) {
      final typeAllowed = _allowedTypes.contains(post.postType);
      final typeMatched = _typeFilter == 'all' || post.postType == _typeFilter;
      return typeAllowed && typeMatched;
    }).toList();
  }

  List<Post> _buildMarketPosts(List<Post> allPosts) {
    return _applyLocalTypeFilter(allPosts);
  }

  String _sortLabel() {
    switch (_sortType) {
      case 'price':
        return '价格低到高';
      case 'price_desc':
        return '价格高到低';
      case 'score':
        return '综合排序';
      case 'time':
      default:
        return '最新发布';
    }
  }

  void _showSortBottomSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF171A22) : Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildSheetHandle(isDark),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '排序方式',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: isDark ? Colors.white : const Color(0xFF111827),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _buildSortOption('time', '最新发布'),
                _buildSortOption('price', '价格从低到高'),
                _buildSortOption('price_desc', '价格从高到低'),
                _buildSortOption('score', '综合排序'),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSortOption(String value, String label) {
    final isSelected = _sortType == value;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const primaryColor = Color(0xFFFF6A2A);

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        Navigator.pop(context);
        if (_sortType != value) {
          _changeSort(value);
        }
      },
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected
                      ? primaryColor
                      : (isDark ? Colors.white : const Color(0xFF111827)),
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_rounded, color: primaryColor, size: 20),
          ],
        ),
      ),
    );
  }

  void _showFilterBottomSheet() {
    var draftType = _typeFilter;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const primary = Color(0xFFFF6B35);
    final options = <MapEntry<String, String>>[
      const MapEntry('all', '全部'),
      ..._allowedTypes.map((type) => MapEntry(type, _typeLabel(type))),
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.36),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.only(top: 80),
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF11141B) : Colors.white,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(child: _buildSheetHandle(isDark)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          '筛选',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color:
                                isDark ? Colors.white : const Color(0xFF101828),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(
                            Icons.close_rounded,
                            color: isDark
                                ? Colors.white70
                                : const Color(0xFF475467),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '商品类型',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color:
                            isDark ? Colors.white70 : const Color(0xFF344054),
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final itemWidth = (constraints.maxWidth - 12) / 2;
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: options.map((entry) {
                            final selected = draftType == entry.key;
                            return SizedBox(
                              width: itemWidth,
                              height: 44,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(14),
                                onTap: () {
                                  setSheetState(() => draftType = entry.key);
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 160),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? primary.withValues(alpha: 0.12)
                                        : (isDark
                                            ? Colors.white
                                                .withValues(alpha: 0.06)
                                            : const Color(0xFFF2F4F7)),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: selected
                                          ? primary
                                          : Colors.transparent,
                                    ),
                                  ),
                                  child: Text(
                                    entry.value,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: selected
                                          ? primary
                                          : (isDark
                                              ? Colors.white70
                                              : const Color(0xFF344054)),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: TextButton(
                              onPressed: draftType == 'all'
                                  ? null
                                  : () {
                                      setSheetState(() => draftType = 'all');
                                    },
                              style: TextButton.styleFrom(
                                backgroundColor: isDark
                                    ? Colors.white.withValues(alpha: 0.06)
                                    : const Color(0xFFFFF2EC),
                                foregroundColor: primary,
                                disabledForegroundColor:
                                    primary.withValues(alpha: 0.35),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: const Text(
                                '清空',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton(
                              onPressed: () {
                                _changeTypeFilter(draftType);
                                Navigator.pop(context);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primary,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: const Text(
                                '完成',
                                style: TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSheetHandle(bool isDark) {
    return Container(
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: isDark ? Colors.white24 : const Color(0xFFD0D5DD),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF06080D) : const Color(0xFFF4F6FB),
      appBar: null,
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
              final marketPosts = _buildMarketPosts(
                _searchQuery.isNotEmpty ? _searchResults : allPosts,
              );

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
                      padding: EdgeInsets.fromLTRB(
                        16,
                        MediaQuery.paddingOf(context).top + 10,
                        16,
                        12,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          _buildSearchAndViewRow(isDark, themeProvider),
                          const SizedBox(height: 16),
                          _buildToolbarRow(isDark, marketPosts.length),
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
                        padding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            AppLayout.floatingNavHeight +
                                AppLayout.floatingNavBottomMargin +
                                AppLayout.fabNavGap +
                                120),
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
                        padding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            AppLayout.floatingNavHeight +
                                AppLayout.floatingNavBottomMargin +
                                AppLayout.fabNavGap +
                                120),
                        sliver: SliverMasonryGrid.count(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
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
              AppLayout.fabNavGap +
              16,
        ),
        child: SizedBox(
          height: 48,
          child: FloatingActionButton.extended(
            heroTag: 'market_fab',
            elevation: 2,
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
      ),
    );
  }

  Widget _buildSearchAndViewRow(
    bool isDark,
    ThemeProvider themeProvider,
  ) {
    return Row(
      children: [
        Expanded(child: _buildSearchBar(isDark)),
        const SizedBox(width: 10),
        _buildViewToggleButton(isDark, themeProvider),
      ],
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF171A22) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black12,
        ),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        onSubmitted: _runSearch,
        textInputAction: TextInputAction.search,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? Colors.white : const Color(0xFF111827),
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 13),
          hintText: '搜索商品、用户或关键词',
          hintStyle: TextStyle(
            fontSize: 14,
            color: isDark ? Colors.white38 : const Color(0xFF98A2B3),
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 20,
            color: isDark ? Colors.white54 : const Color(0xFF667085),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 34, minHeight: 34),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: isDark ? Colors.white54 : const Color(0xFF667085),
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

  Widget _buildViewToggleButton(bool isDark, ThemeProvider themeProvider) {
    return SizedBox(
      width: 46,
      height: 46,
      child: Material(
        color: isDark ? const Color(0xFF171A22) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            themeProvider.setMarketIsListView(
              !themeProvider.marketIsListView,
            );
          },
          child: Icon(
            themeProvider.marketIsListView
                ? Icons.grid_view_rounded
                : Icons.view_agenda_outlined,
            size: 21,
            color: isDark ? Colors.white : const Color(0xFF111827),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbarRow(bool isDark, int count) {
    final sectionTitle =
        _searchQuery.isNotEmpty ? '搜索结果' : (widget.titleOverride ?? '最新商品');
    final hasFilter = _activeFilterCount > 0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              sectionTitle,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: isDark ? Colors.white : const Color(0xFF111827),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : const Color(0xFFEFF3F8),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count条',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isDark ? Colors.white54 : const Color(0xFF667085),
                  ),
                ),
              ),
            ],
          ],
        ),
        Row(
          children: [
            _buildToolbarButton(
              isDark: isDark,
              label: _sortLabel(),
              icon: Icons.keyboard_arrow_down_rounded,
              onTap: _showSortBottomSheet,
            ),
            const SizedBox(width: 8),
            _buildToolbarButton(
              isDark: isDark,
              label: hasFilter ? _typeLabel(_typeFilter) : '筛选',
              icon: Icons.tune_rounded,
              highlighted: hasFilter,
              onTap: _showFilterBottomSheet,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildToolbarButton({
    required bool isDark,
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    return SizedBox(
      height: 34,
      child: Material(
        color: highlighted
            ? const Color(0xFFFFEFE8)
            : (isDark ? const Color(0xFF171A22) : Colors.white),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: highlighted
                        ? const Color(0xFFFF6B35)
                        : (isDark ? Colors.white70 : const Color(0xFF344054)),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  icon,
                  size: 17,
                  color: highlighted
                      ? const Color(0xFFFF6B35)
                      : (isDark ? Colors.white60 : const Color(0xFF667085)),
                ),
              ],
            ),
          ),
        ),
      ),
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
