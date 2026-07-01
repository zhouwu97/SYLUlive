import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../models/post.dart';
import '../models/user.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/cached_avatar.dart';
import '../widgets/glass_container.dart';
import '../widgets/post_card.dart';
import 'post_detail_screen.dart';
import 'user_home_screen.dart';

class SearchResultsScreen extends StatefulWidget {
  final String query;
  final int boardId;

  const SearchResultsScreen({super.key, required this.query, this.boardId = 1});

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  static const int _pageSize = 20;

  late final TextEditingController _searchController;
  final ScrollController _scrollController = ScrollController();
  String _query = '';
  String _type = 'posts';
  String _sort = 'relevance';
  List<Post> _posts = [];
  List<User> _users = [];
  int _page = 1;
  int _total = 0;
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _query = widget.query.trim();
    _searchController = TextEditingController(text: _query);
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _submitSearch(String raw) async {
    final next = raw.trim();
    if (next.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _query = next);
    await _search();
  }

  Future<void> _changeType(String type) async {
    if (_type == type) return;
    setState(() {
      _type = type;
      _sort = 'relevance';
    });
    await _search();
  }

  Future<void> _changeSort(String sort) async {
    if (_sort == sort) return;
    setState(() => _sort = sort);
    await _search();
  }

  Future<void> _search() async {
    if (_query.isEmpty) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _page = 1;
      _hasMore = true;
      _posts = [];
      _users = [];
    });
    await _fetchPage(1);
  }

  Future<void> _loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    await _fetchPage(_page + 1);
  }

  Future<void> _fetchPage(int page) async {
    try {
      final auth = context.read<AuthProvider>();
      final response = await auth.dio.get(
        '/search',
        queryParameters: {
          'q': _query,
          'type': _type,
          'sort': _sort,
          'page': page,
          'limit': _pageSize,
          if (_type == 'posts') 'board': widget.boardId,
        },
      );
      if (!mounted) return;

      final items = (response.data['items'] as List?) ?? const [];
      final total = (response.data['total'] as num?)?.toInt() ?? items.length;
      setState(() {
        if (_type == 'posts') {
          _posts.addAll(
            items.map(
              (item) => Post.fromJson(Map<String, dynamic>.from(item as Map)),
            ),
          );
        } else {
          _users.addAll(
            items.map(
              (item) => User.fromJson(Map<String, dynamic>.from(item as Map)),
            ),
          );
        }
        _total = total;
        _page = page;
        final loadedCount = _type == 'posts' ? _posts.length : _users.length;
        _hasMore = loadedCount < total && items.isNotEmpty;
        _isLoading = false;
        _isLoadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is Exception ? error.toString() : '搜索失败';
        _isLoading = false;
        _isLoadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final useCustomBackground = themeProvider.shouldShowCustomBackground;
    final cleanLightMode = !useCustomBackground && !isDark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (cleanLightMode
              ? SystemUiOverlayStyle.dark
              : SystemUiOverlayStyle.light)
          .copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(child: _buildBackground(themeProvider, isDark)),
            SafeArea(
              child: Column(
                children: [
                  _buildTopBar(isDark),
                  _buildTypeTabs(isDark),
                  _buildSortBar(isDark),
                  Expanded(child: _buildResults(isDark)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 14, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: GlassContainer(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              borderRadius: 24,
              blur: 14,
              opacity: 0.88,
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onSubmitted: _submitSearch,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  hintText: '搜索账号、用户或帖子关键词',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_upward_rounded, size: 19),
                    onPressed: () => _submitSearch(_searchController.text),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTypeTabs(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '搜索 “$_query”',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white60 : Colors.black54,
              ),
            ),
          ),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'posts',
                label: Text('帖子'),
                icon: Icon(Icons.article_outlined, size: 17),
              ),
              ButtonSegment(
                value: 'users',
                label: Text('用户'),
                icon: Icon(Icons.person_search_outlined, size: 17),
              ),
            ],
            selected: {_type},
            showSelectedIcon: false,
            onSelectionChanged: (selected) => _changeType(selected.first),
          ),
        ],
      ),
    );
  }

  Widget _buildSortBar(bool isDark) {
    final options = _type == 'posts'
        ? const [('relevance', '综合'), ('latest', '最新'), ('hot', '热门')]
        : const [('relevance', '综合'), ('newest', '最新注册')];

    return SizedBox(
      height: 45,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final option = options[index];
          return ChoiceChip(
            label: Text(option.$2),
            selected: _sort == option.$1,
            onSelected: (_) => _changeSort(option.$1),
          );
        },
      ),
    );
  }

  Widget _buildResults(bool isDark) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _posts.isEmpty && _users.isEmpty) {
      return Center(
        child: GlassContainer(
          padding: const EdgeInsets.all(28),
          borderRadius: 20,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 48),
              const SizedBox(height: 12),
              const Text('搜索失败，请检查网络后重试'),
              const SizedBox(height: 14),
              FilledButton.tonal(onPressed: _search, child: const Text('重新搜索')),
            ],
          ),
        ),
      );
    }

    final itemCount = _type == 'posts' ? _posts.length : _users.length;
    if (itemCount == 0) {
      return Center(
        child: Text(
          _type == 'posts' ? '没有找到相关帖子' : '没有找到相关用户',
          style: TextStyle(color: isDark ? Colors.white60 : Colors.black54),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _search,
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 100),
        itemCount: itemCount + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 10),
              child: Text(
                '找到 $_total 条结果',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            );
          }
          if (index == itemCount + 1) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: _isLoadingMore
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : Text(
                        _hasMore ? '' : '已显示全部结果',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.black38,
                        ),
                      ),
              ),
            );
          }
          return _type == 'posts'
              ? _buildPostItem(_posts[index - 1])
              : _buildUserItem(_users[index - 1], isDark);
        },
      ),
    );
  }

  Widget _buildPostItem(Post post) {
    return PostCard(
      post: post,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PostDetailScreen(
            postId: post.id,
            isMarket: post.boardId == 2,
            initialPost: post,
          ),
        ),
      ),
    );
  }

  Widget _buildUserItem(User user, bool isDark) {
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: 18,
      blur: 10,
      opacity: isDark ? 0.14 : 0.62,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => UserHomeScreen(userId: user.id)),
      ),
      child: Row(
        children: [
          CachedAvatar(
            imageUrl:
                user.avatar.isEmpty ? null : ApiConstants.fullUrl(user.avatar),
            radius: 25,
            fallbackText: user.nickname,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.nickname.isEmpty ? '用户${user.id}' : user.nickname,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '账号 ${user.studentId}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                if (user.eduCollege.isNotEmpty)
                  Text(
                    '${user.eduCollege} ${user.eduMajor}'.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white54 : Colors.black45,
                    ),
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }

  Widget _buildDefaultBackground(bool isDark) {
    return ColoredBox(
      color: isDark ? const Color(0xFF131720) : const Color(0xFFF4F6FB),
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    final path = themeProvider.getCustomBackgroundImageFor(context);
    if (themeProvider.shouldShowCustomBackground &&
        path != null &&
        path.isNotEmpty) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ThemeProvider.isBundledAssetBackground(path)
              ? Image.asset(
                  ThemeProvider.resolveBundledAssetPath(path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark),
                )
              : ThemeProvider.isLocalFileBackground(path)
                  ? Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildDefaultBackground(isDark),
                    )
                  : Image.network(
                      path,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildDefaultBackground(isDark),
                    ),
          Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.32)
                : Colors.white.withValues(alpha: 0.22),
          ),
        ],
      );
    }
    return _buildDefaultBackground(isDark);
  }
}
