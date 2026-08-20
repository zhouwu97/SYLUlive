import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:provider/provider.dart';

import '../models/post.dart';
import '../providers/auth_provider.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../services/app_resume_coordinator.dart';
import '../theme/app_motion.dart';
import '../utils/responsive_util.dart';
import '../utils/app_navigator.dart';
import '../widgets/market_post_card.dart';
import 'create_post_screen.dart';
import 'post_detail_screen.dart';

abstract final class AppLayout {
  static const double floatingNavHeight = 64;
  static const double floatingNavBottomMargin = 12;
  static const double fabNavGap = 12;
}

final class _MarketTokens {
  static Color pageBg(bool isDark) =>
      isDark ? const Color(0xFF111315) : const Color(0xFFFFFAF4);

  static Color cardBg(bool isDark) =>
      isDark ? const Color(0xFF1E2226) : Colors.white;

  static Color accent(bool isDark) =>
      isDark ? const Color(0xFFFFA06D) : const Color(0xFFFF7A45);

  static Color accentSoft(bool isDark) => isDark
      ? const Color(0xFFFFA06D).withValues(alpha: 0.14)
      : const Color(0xFFFFF0E8);

  static Color borderColor(bool isDark) =>
      isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFF1E5DC);

  static Color titleColor(bool isDark) =>
      isDark ? Colors.white : const Color(0xFF1F2328);

  static Color subColor(bool isDark) =>
      isDark ? Colors.grey.shade400 : const Color(0xFF747B82);

  static const double cardRadius = 18;
  static const double chipRadius = 999;
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
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;
  String _sortType = 'time';
  String _searchQuery = '';
  bool _isSearching = false;
  List<Post> _searchResults = [];
  String _typeFilter = 'all';
  int _searchGeneration = 0;
  VoidCallback? _unregisterResumeRefresh;

  static const _marketPostTypes = ['sell', 'buy', 'lost', 'found', 'proxy'];

  List<MapEntry<String, String>> get _visibleCategoryOptions => [
        const MapEntry('all', '全部'),
        for (final type in _allowedTypes) MapEntry(type, _typeLabel(type)),
      ];

  List<String> get _allowedTypes =>
      widget.onlyPostTypes == null || widget.onlyPostTypes!.isEmpty
          ? _marketPostTypes
          : widget.onlyPostTypes!;

  String? get _selectedServerType => _typeFilter == 'all' ? null : _typeFilter;

  String get _defaultPublishTypeForCurrentView {
    if (_typeFilter != 'all' && _allowedTypes.contains(_typeFilter)) {
      return _typeFilter;
    }
    if (_allowedTypes.contains('sell')) return 'sell';
    return _allowedTypes.first;
  }

  String _publishLabel(String type) {
    switch (type) {
      case 'buy':
        return '发布求购';
      case 'lost':
        return '发布失物';
      case 'found':
        return '发布招领';
      case 'proxy':
        return '发布办事';
      case 'sell':
      default:
        return '发布商品';
    }
  }

  String _emptyTitle() {
    if (_searchQuery.isNotEmpty) return '没有找到匹配内容';
    if (_typeFilter != 'all') return '还没有${_typeLabel(_typeFilter)}';
    return '还没有商品';
  }

  String _emptySubtitle() {
    if (_searchQuery.isNotEmpty) return '换个关键词试试';
    if (_typeFilter != 'all') return '发布第一条${_typeLabel(_typeFilter)}信息';
    return '发布第一条闲置、求购或办事信息';
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _unregisterResumeRefresh =
        AppResumeCoordinator.instance.registerVisibleRefresh(
      _refreshCurrent,
      isVisible: () => currentHomeTabIndex.value == 1,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PostProvider>().loadPosts(
            boardId: 2,
            type: _selectedServerType,
            sort: _sortType,
          );
    });
  }

  @override
  void dispose() {
    _unregisterResumeRefresh?.call();
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients ||
        _searchQuery.isNotEmpty ||
        _isSearching) {
      return;
    }
    if (_scrollController.position.extentAfter < 560) {
      final provider = context.read<PostProvider>();
      if (!provider.isLoadingFor(
            2,
            type: _selectedServerType,
            sort: _sortType,
          ) &&
          provider.hasMoreFor(
            2,
            type: _selectedServerType,
            sort: _sortType,
          )) {
        provider.loadPosts(
          boardId: 2,
          type: _selectedServerType,
          sort: _sortType,
        );
      }
    }
  }

  Future<void> _runSearch(String raw) async {
    final query = raw.trim();
    final generation = ++_searchGeneration;
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
          type: _typeFilter == 'all' ? null : _typeFilter,
          sort: _sortType,
          query: query,
          limit: 100,
        );

    if (!mounted || generation != _searchGeneration || _searchQuery != query) {
      return;
    }

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
    await context.read<PostProvider>().refresh(
          boardId: 2,
          type: _selectedServerType,
          sort: _sortType,
        );
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
        return '办事';
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
    if (_searchQuery.isNotEmpty) {
      _runSearch(_searchQuery);
    } else {
      unawaited(_refreshCurrent());
    }
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
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            decoration: BoxDecoration(
              color: _MarketTokens.cardBg(isDark),
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
                        color: _MarketTokens.titleColor(isDark),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(ctx),
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
    final accent = _MarketTokens.accent(isDark);

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
                  color: isSelected ? accent : _MarketTokens.titleColor(isDark),
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
            if (isSelected) Icon(Icons.check_rounded, color: accent, size: 20),
          ],
        ),
      ),
    );
  }

  void _showFilterBottomSheet() {
    var draftType = _typeFilter;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = _MarketTokens.accent(isDark);
    final options = <MapEntry<String, String>>[
      const MapEntry('all', '全部'),
      ..._allowedTypes.map((type) => MapEntry(type, _typeLabel(type))),
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.36),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              top: false,
              child: Container(
                margin: const EdgeInsets.only(top: 80),
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                decoration: BoxDecoration(
                  color: _MarketTokens.cardBg(isDark),
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
                            color: _MarketTokens.titleColor(isDark),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.pop(ctx),
                          icon: Icon(
                            Icons.close_rounded,
                            color: _MarketTokens.subColor(isDark),
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
                        color: _MarketTokens.subColor(isDark),
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
                                        ? _MarketTokens.accentSoft(isDark)
                                        : (isDark
                                            ? Colors.white
                                                .withValues(alpha: 0.06)
                                            : const Color(0xFFF2F4F7)),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: selected
                                          ? accent
                                          : Colors.transparent,
                                    ),
                                  ),
                                  child: Text(
                                    entry.value,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: selected
                                          ? accent
                                          : _MarketTokens.subColor(isDark),
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
                                backgroundColor:
                                    _MarketTokens.accentSoft(isDark),
                                foregroundColor: accent,
                                disabledForegroundColor:
                                    accent.withValues(alpha: 0.35),
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
                                Navigator.pop(ctx);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: accent,
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
      backgroundColor: _MarketTokens.pageBg(isDark),
      appBar: null,
      body: Consumer<PostProvider>(
        builder: (context, postProvider, child) {
          final allPosts = postProvider.postsFor(
            2,
            type: _selectedServerType,
            sort: _sortType,
          );
          final marketPosts = _buildMarketPosts(
            _searchQuery.isNotEmpty ? _searchResults : allPosts,
          );
          final isLoading = postProvider.isLoadingFor(
            2,
            type: _selectedServerType,
            sort: _sortType,
          );
          final hasLoaded = postProvider.hasLoadedFor(
            2,
            type: _selectedServerType,
            sort: _sortType,
          );
          final feedError = postProvider.errorFor(
            2,
            type: _selectedServerType,
            sort: _sortType,
          );

          if (isLoading && allPosts.isEmpty && !hasLoaded) {
            return const Center(child: CircularProgressIndicator());
          }

          final initialError =
              _searchQuery.isEmpty && allPosts.isEmpty && feedError != null;

          return Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration:
                      BoxDecoration(color: _MarketTokens.pageBg(isDark)),
                ),
              ),
              RefreshIndicator(
                onRefresh: _refreshCurrent,
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        MediaQuery.paddingOf(context).top + 8,
                        16,
                        8,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate([
                          _buildHeader(isDark, themeProvider),
                          const SizedBox(height: 12),
                          _buildSearchBar(isDark),
                          const SizedBox(height: 10),
                          _buildCategoryRow(isDark),
                          const SizedBox(height: 8),
                          _buildSortFilterRow(isDark, marketPosts.length),
                          if (_searchQuery.isEmpty &&
                              feedError != null &&
                              allPosts.isNotEmpty)
                            _buildStaleErrorBanner(
                              isDark,
                              feedError,
                            ),
                        ]),
                      ),
                    ),
                    if (_isSearching)
                      const SliverFillRemaining(
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (initialError)
                      SliverToBoxAdapter(
                        child: _buildInitialErrorState(
                          isDark,
                          feedError,
                        ),
                      )
                    else if (marketPosts.isEmpty)
                      SliverToBoxAdapter(
                        child: _buildEmptyState(isDark),
                      )
                    else if (themeProvider.marketIsListView)
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            marketPosts.length <= 2
                                ? 12.0
                                : AppLayout.floatingNavHeight +
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
                        padding: EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            marketPosts.length <= 2
                                ? 12.0
                                : AppLayout.floatingNavHeight +
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
                    if (_searchQuery.isEmpty &&
                        !_isSearching &&
                        marketPosts.isNotEmpty &&
                        (isLoading || feedError != null))
                      SliverToBoxAdapter(
                        child: _buildPaginationFooter(
                          isDark,
                          isLoading: isLoading,
                          error: feedError,
                        ),
                      ),
                    if (!_isSearching &&
                        _searchQuery.isEmpty &&
                        marketPosts.isNotEmpty &&
                        marketPosts.length <= 2)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            AppLayout.floatingNavHeight +
                                AppLayout.floatingNavBottomMargin +
                                AppLayout.fabNavGap +
                                16),
                        sliver: SliverToBoxAdapter(
                            child: _buildSparseGuidance(isDark)),
                      ),
                  ],
                ),
              ),
              if (marketPosts.isNotEmpty)
                Positioned(
                  right: 0,
                  bottom: AppLayout.floatingNavHeight +
                      AppLayout.floatingNavBottomMargin +
                      AppLayout.fabNavGap +
                      16,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: SizedBox(
                      height: 48,
                      child: FloatingActionButton.extended(
                        heroTag: 'market_fab',
                        elevation: 2,
                        label: const Text('发布'),
                        icon: const Icon(Icons.add),
                        backgroundColor: _MarketTokens.accent(isDark),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        onPressed: () async {
                          final authProvider = context.read<AuthProvider>();
                          if (!authProvider.isLoggedIn) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('请先登录')),
                            );
                            Navigator.pushNamed(context, '/login');
                            return;
                          }
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => CreatePostScreen(
                                boardId: 2,
                                defaultPostType:
                                    _defaultPublishTypeForCurrentView,
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
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openMarketPublish(String defaultPostType) async {
    final authProvider = context.read<AuthProvider>();
    if (!authProvider.isLoggedIn) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录')),
      );
      Navigator.pushNamed(context, '/login');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CreatePostScreen(
          boardId: 2,
          defaultPostType: defaultPostType,
          allowedPostTypes: widget.onlyPostTypes,
        ),
      ),
    );
    if (mounted) {
      await _refreshCurrent();
    }
  }

  Widget _buildSparseGuidance(bool isDark) {
    final showBuy = _allowedTypes.contains('buy');
    final showProxy = _allowedTypes.contains('proxy');
    if (!showBuy && !showProxy) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: _MarketTokens.cardBg(isDark),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _MarketTokens.borderColor(isDark)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '还没找到想要的？',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _MarketTokens.titleColor(isDark),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '发布求购或办事，让同学主动联系你',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: _MarketTokens.subColor(isDark),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (showBuy)
            _buildGuidanceChip('发布求购', isDark, () => _openMarketPublish('buy')),
          if (showBuy && showProxy) const SizedBox(width: 8),
          if (showProxy)
            _buildGuidanceChip(
                '发布办事', isDark, () => _openMarketPublish('proxy')),
        ],
      ),
    );
  }

  Widget _buildGuidanceChip(
    String label,
    bool isDark,
    VoidCallback onTap,
  ) {
    return Material(
      color: _MarketTokens.accentSoft(isDark),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _MarketTokens.accent(isDark),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark, ThemeProvider themeProvider) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.titleOverride ?? '集市',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: _MarketTokens.titleColor(isDark),
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '校园二手、求购和办事信息',
                style: TextStyle(
                  fontSize: 12,
                  color: _MarketTokens.subColor(isDark),
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
        _buildViewToggleButton(isDark, themeProvider),
      ],
    );
  }

  Widget _buildViewToggleButton(bool isDark, ThemeProvider themeProvider) {
    final isGrid = !themeProvider.marketIsListView;
    return SizedBox(
      width: 42,
      height: 42,
      child: Material(
        color: isGrid
            ? _MarketTokens.accentSoft(isDark)
            : _MarketTokens.cardBg(isDark),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            themeProvider.setMarketIsListView(
              !themeProvider.marketIsListView,
            );
          },
          child: Icon(
            themeProvider.marketIsListView
                ? Icons.grid_view_rounded
                : Icons.view_agenda_outlined,
            size: 20,
            color: isGrid
                ? _MarketTokens.accent(isDark)
                : _MarketTokens.subColor(isDark),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    final hasText = _searchController.text.isNotEmpty;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _MarketTokens.cardBg(isDark),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _MarketTokens.borderColor(isDark)),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.015),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
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
          color: _MarketTokens.titleColor(isDark),
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
          suffixIcon: !hasText
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

  Widget _buildCategoryRow(bool isDark) {
    final accent = _MarketTokens.accent(isDark);
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _visibleCategoryOptions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final entry = _visibleCategoryOptions[index];
          final selected = _typeFilter == entry.key;
          return _buildChip(
            isDark: isDark,
            label: entry.value,
            selected: selected,
            accent: accent,
            onTap: () => _changeTypeFilter(entry.key),
          );
        },
      ),
    );
  }

  Widget _buildChip({
    required bool isDark,
    required String label,
    required bool selected,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppMotion.fast),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? _MarketTokens.accentSoft(isDark)
              : _MarketTokens.cardBg(isDark),
          borderRadius: BorderRadius.circular(_MarketTokens.chipRadius),
          border: Border.all(
            color: selected
                ? accent.withValues(alpha: 0.32)
                : _MarketTokens.borderColor(isDark),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? accent : _MarketTokens.subColor(isDark),
          ),
        ),
      ),
    );
  }

  Widget _buildSortFilterRow(bool isDark, int count) {
    final accent = _MarketTokens.accent(isDark);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          count > 0 ? '共 $count 条' : '',
          style: TextStyle(
            fontSize: 12,
            color: _MarketTokens.subColor(isDark),
            fontWeight: FontWeight.w600,
          ),
        ),
        Row(
          children: [
            _buildPillButton(
              isDark: isDark,
              label: _sortLabel(),
              icon: Icons.keyboard_arrow_down_rounded,
              accent: accent,
              onTap: _showSortBottomSheet,
            ),
            const SizedBox(width: 8),
            _buildPillButton(
              isDark: isDark,
              label: '筛选',
              icon: Icons.tune_rounded,
              accent: accent,
              onTap: _showFilterBottomSheet,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPillButton({
    required bool isDark,
    required String label,
    required IconData icon,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 32,
      child: Material(
        color: _MarketTokens.cardBg(isDark),
        borderRadius: BorderRadius.circular(_MarketTokens.chipRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(_MarketTokens.chipRadius),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _MarketTokens.titleColor(isDark),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(icon, size: 16, color: _MarketTokens.subColor(isDark)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMarketCard(Post post, [bool inGrid = false]) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 0),
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

  Widget _buildInitialErrorState(bool isDark, String error) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 48, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        decoration: BoxDecoration(
          color: _MarketTokens.cardBg(isDark),
          borderRadius: BorderRadius.circular(_MarketTokens.cardRadius),
          border: Border.all(color: _MarketTokens.borderColor(isDark)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_rounded,
              size: 40,
              color: isDark ? Colors.white54 : Colors.grey[500],
            ),
            const SizedBox(height: 12),
            Text(
              '集市加载失败',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: _MarketTokens.titleColor(isDark),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: _MarketTokens.subColor(isDark),
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: () => context.read<PostProvider>().refresh(
                    boardId: 2,
                    type: _selectedServerType,
                    sort: _sortType,
                  ),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStaleErrorBanner(bool isDark, String error) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.orange.withValues(alpha: 0.12)
            : const Color(0xFFFFF4E5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? Colors.orange.withValues(alpha: 0.25)
              : const Color(0xFFF5C27A),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '刷新失败，仍显示上次内容：$error',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? Colors.orange[100] : Colors.orange[900],
              ),
            ),
          ),
          TextButton(
            onPressed: () => context.read<PostProvider>().refresh(
                  boardId: 2,
                  type: _selectedServerType,
                  sort: _sortType,
                ),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildPaginationFooter(
    bool isDark, {
    required bool isLoading,
    required String? error,
  }) {
    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Center(
        child: TextButton.icon(
          onPressed: () => context.read<PostProvider>().loadPosts(
                boardId: 2,
                type: _selectedServerType,
                sort: _sortType,
              ),
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(
            '加载更多失败，点击重试',
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black54),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final title = _emptyTitle();
    final subtitle = _emptySubtitle();
    final defaultType = _defaultPublishTypeForCurrentView;
    final accent = _MarketTokens.accent(isDark);
    final isNoResults = title.contains('没有找到');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 48, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
        decoration: BoxDecoration(
          color: _MarketTokens.cardBg(isDark),
          borderRadius: BorderRadius.circular(_MarketTokens.cardRadius),
          border: Border.all(color: _MarketTokens.borderColor(isDark)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _MarketTokens.accentSoft(isDark),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.inventory_2_outlined,
                size: 34,
                color: accent.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: _MarketTokens.titleColor(isDark),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: _MarketTokens.subColor(isDark),
                height: 1.4,
              ),
            ),
            if (!isNoResults) ...[
              const SizedBox(height: 24),
              SizedBox(
                width: 200,
                height: 44,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    final authProvider = context.read<AuthProvider>();
                    if (!authProvider.isLoggedIn) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请先登录')),
                      );
                      Navigator.pushNamed(context, '/login');
                      return;
                    }
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CreatePostScreen(
                          boardId: 2,
                          defaultPostType: defaultType,
                          allowedPostTypes: widget.onlyPostTypes,
                        ),
                      ),
                    );
                    if (mounted) {
                      await _refreshCurrent();
                    }
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(
                    _publishLabel(defaultType),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
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
