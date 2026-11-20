import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../widgets/app_card.dart';
import '../widgets/app_page_background.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/dish_review_tile.dart';
import 'canteen_dish_detail_screen.dart' show dishPagePadding;

/// 某道菜的全部评价（分页加载，每位同学只显示最近一条）。
class CanteenDishReviewsScreen extends StatefulWidget {
  final int dishId;
  final String dishName;

  const CanteenDishReviewsScreen({
    super.key,
    required this.dishId,
    required this.dishName,
  });

  @override
  State<CanteenDishReviewsScreen> createState() =>
      _CanteenDishReviewsScreenState();
}

class _CanteenDishReviewsScreenState extends State<CanteenDishReviewsScreen> {
  static const _pageSize = 20;

  final List<Map<String, dynamic>> _items = [];
  final ScrollController _scroll = ScrollController();
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _total = 0;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 400) _loadMore();
    });
    _reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    setState(() {
      _initialLoading = true;
      _error = null;
    });
    final provider = context.read<CanteenProvider>();
    final page =
        await provider.loadDishReviewPage(widget.dishId, limit: _pageSize);
    if (!mounted || generation != _generation) return;
    setState(() {
      _initialLoading = false;
      if (page == null) {
        _error = provider.errorMessage ?? '评价加载失败，请重试';
        return;
      }
      _items
        ..clear()
        ..addAll(page.items);
      _total = page.total;
      _hasMore = page.hasMore;
    });
  }

  Future<void> _loadMore() async {
    if (_initialLoading || _loadingMore || !_hasMore || _error != null) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final provider = context.read<CanteenProvider>();
    final page = await provider.loadDishReviewPage(widget.dishId,
        offset: _items.length, limit: _pageSize);
    if (!mounted || generation != _generation) return;
    setState(() {
      _loadingMore = false;
      if (page == null) {
        // 翻页失败不清空已有内容，底部给出重试。
        _hasMore = true;
        _error = provider.errorMessage ?? '加载失败';
        return;
      }
      _items.addAll(page.items);
      _total = page.total;
      _hasMore = page.hasMore;
    });
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  Widget _buildPage(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
      appBar: AppBar(
        title: Text('「${widget.dishName}」的评价'),
        backgroundColor:
            AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
        foregroundColor: CanteenTheme.textPrimaryColor(isDark),
      ),
      body: _buildBody(isDark),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_initialLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty && _error != null) {
      return CanteenEmptyState(
        title: '评价加载失败',
        subtitle: _error,
        actionLabel: '重新加载',
        onAction: _reload,
      );
    }
    if (_items.isEmpty) {
      return const CanteenEmptyState(
        icon: Icons.rate_review_outlined,
        title: '还没有同学评价这道菜',
      );
    }
    final currentUserId = context.read<AuthProvider>().user?.id;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: dishPagePadding(context, top: 8, bottom: 32),
        itemCount: _items.length + 2,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, index) {
          if (index == 0) {
            return Text(
              '共 $_total 位同学评价过',
              style: TextStyle(
                fontSize: 12,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            );
          }
          if (index == _items.length + 1) return _buildFooter(isDark);
          final review = _items[index - 1];
          return AppCardSurface(
            padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
            decoration: BoxDecoration(
              color: CanteenTheme.surfaceBg(isDark),
              borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
              border: Border.all(color: CanteenTheme.borderColor(isDark)),
            ),
            child: DishReviewTile(
              review: review,
              canReport: currentUserId != (review['user_id'] as num?)?.toInt(),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter(bool isDark) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null && _hasMore) {
      return Center(
        child: TextButton(
          onPressed: () {
            setState(() => _error = null);
            _loadMore();
          },
          style: TextButton.styleFrom(
            foregroundColor: CanteenTheme.accentStrongColor(isDark),
          ),
          child: const Text('加载失败，点击重试'),
        ),
      );
    }
    if (!_hasMore) {
      return Center(
        child: Text(
          '没有更多了',
          style: TextStyle(
              fontSize: 12, color: CanteenTheme.textTertiaryColor(isDark)),
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}
