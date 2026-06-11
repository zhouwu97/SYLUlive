import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/post.dart';
import '../providers/post_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
import '../widgets/post_card.dart';
import 'post_detail_screen.dart';

class SearchResultsScreen extends StatefulWidget {
  final String query;
  final int boardId;

  const SearchResultsScreen({
    super.key,
    required this.query,
    this.boardId = 1,
  });

  @override
  State<SearchResultsScreen> createState() => _SearchResultsScreenState();
}

class _SearchResultsScreenState extends State<SearchResultsScreen> {
  List<Post> _results = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _doSearch();
  }

  Future<void> _doSearch() async {
    if (mounted) setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final posts = await context.read<PostProvider>().searchPosts(
            boardId: widget.boardId,
            query: widget.query,
            limit: 50,
          );
      if (!mounted) return;
      setState(() {
        _results = posts;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
        title: Text(
          '搜索: ${widget.query}',
          style: TextStyle(
            fontSize: 16,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
      ),
      body: Stack(
        children: [
          // 背景
          Positioned.fill(
            child: _buildBackground(themeProvider, isDark),
          ),
          // 内容
          SafeArea(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _buildErrorView(isDark)
                    : _results.isEmpty
                        ? _buildEmptyView(isDark)
                        : RefreshIndicator(
                            onRefresh: _doSearch,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                              itemCount: _results.length,
                              itemBuilder: (context, index) {
                                final post = _results[index];
                                return PostCard(
                                  post: post,
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => PostDetailScreen(
                                          postId: post.id,
                                          isMarket: widget.boardId == 2,
                                          initialPost: post,
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
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
                ? Colors.black.withValues(alpha: 0.32)
                : Colors.white.withValues(alpha: 0.22),
          ),
        ],
      );
    }
    return _buildDefaultBg(isDark);
  }

  Widget _buildErrorView(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(32),
        borderRadius: 20,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48,
                color: isDark ? Colors.white30 : Colors.grey[400]),
            const SizedBox(height: 14),
            Text(_error!,
                style: TextStyle(
                    color: isDark ? Colors.white60 : Colors.grey[600])),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _doSearch,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyView(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(32),
        borderRadius: 20,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48,
                color: isDark ? Colors.white30 : Colors.grey[400]),
            const SizedBox(height: 14),
            Text('没有找到"${widget.query}"相关帖子',
                style: TextStyle(
                    fontSize: 15,
                    color: isDark ? Colors.white60 : Colors.grey[600])),
            const SizedBox(height: 6),
            Text('试试换个关键词',
                style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white38 : Colors.grey[500])),
          ],
        ),
      ),
    );
  }
}
