import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/canteen_home.dart';
import '../providers/canteen_discovery_provider.dart';
import '../utils/responsive_util.dart';
import '../widgets/app_page_background.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_hot_dish_card.dart';
import '../widgets/canteen/canteen_theme.dart';
import 'canteen_dish_detail_screen.dart';

/// 全校热门菜品（首页“热门菜品 · 更多”）：按近 30 天被评价提到的次数排序，分页加载。
class CanteenHotDishesScreen extends StatefulWidget {
  const CanteenHotDishesScreen({super.key});

  @override
  State<CanteenHotDishesScreen> createState() => _CanteenHotDishesScreenState();
}

class _CanteenHotDishesScreenState extends State<CanteenHotDishesScreen> {
  static const _pageSize = 20;

  final List<CanteenHotDish> _dishes = [];
  final ScrollController _scroll = ScrollController();
  bool _initialLoading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600) _loadMore();
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
    final provider = context.read<CanteenDiscoveryProvider>();
    final page = await provider.loadHotDishPage(limit: _pageSize);
    if (!mounted || generation != _generation) return;
    setState(() {
      _initialLoading = false;
      if (page == null) {
        _error = provider.lastError ?? '热门菜品加载失败，请重试';
        return;
      }
      _dishes
        ..clear()
        ..addAll(page.items);
      _hasMore = page.hasMore;
    });
  }

  Future<void> _loadMore() async {
    if (_initialLoading || _loadingMore || !_hasMore || _error != null) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    final provider = context.read<CanteenDiscoveryProvider>();
    // 服务端按全部菜品分页；客户端会过滤掉无图项，所以 offset 以服务端条数为准。
    final page =
        await provider.loadHotDishPage(offset: _serverOffset, limit: _pageSize);
    if (!mounted || generation != _generation) return;
    setState(() {
      _loadingMore = false;
      if (page == null) {
        _error = provider.lastError ?? '加载失败';
        return;
      }
      _serverOffset += _pageSize;
      _dishes.addAll(page.items);
      _hasMore = page.hasMore;
    });
  }

  int _serverOffset = _pageSize;

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  Widget _buildPage(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
      appBar: AppBar(
        title: const Text('热门菜品'),
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
    if (_dishes.isEmpty && _error != null) {
      return CanteenEmptyState(
        title: '热门菜品加载失败',
        subtitle: _error,
        actionLabel: '重新加载',
        onAction: () {
          _serverOffset = _pageSize;
          _reload();
        },
      );
    }
    if (_dishes.isEmpty) {
      return const CanteenEmptyState(
        icon: Icons.photo_camera_outlined,
        title: '还没有菜品实拍',
        subtitle: '在食堂评价中关联菜品并上传实拍',
      );
    }
    return RefreshIndicator(
      onRefresh: () {
        _serverOffset = _pageSize;
        return _reload();
      },
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                '按近 30 天同学评价提到的次数排序',
                style: TextStyle(
                  fontSize: 12,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) => SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: ResponsiveUtil.gridColumnCount(
                      constraints.crossAxisExtent,
                      spacing: 10),
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 0.92,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildDishCard(isDark, _dishes[index]),
                  childCount: _dishes.length,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(child: _buildFooter(isDark)),
        ],
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
          child: const Text('加载失败，点击重试'),
        ),
      );
    }
    return const SizedBox(height: 32);
  }

  Widget _buildDishCard(bool isDark, CanteenHotDish dish) {
    return CanteenHotDishCard(
      dish: dish,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CanteenDishDetailScreen(
            canteenId: dish.canteenId,
            dishId: dish.id,
            dishName: dish.name,
            canteenName: dish.canteenName,
          ),
        ),
      ),
    );
  }
}
