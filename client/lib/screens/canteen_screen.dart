import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/canteen.dart';
import '../models/canteen_home.dart';
import '../models/canteen_dish.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_discovery_provider.dart';
import '../providers/canteen_provider.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/canteen_status_image.dart';
import '../widgets/canteen/canteen_hero_recommendation.dart';
import '../widgets/canteen/canteen_ranking_entry.dart';
import '../widgets/canteen/canteen_recent_review_card.dart';
import '../widgets/image_upload_widget.dart';
import 'canteen_detail_screen.dart';
import 'canteen_dish_detail_screen.dart';
import 'canteen_ranking_screen.dart';
import 'canteen_review_editor_screen.dart';

/// 校园餐饮发现首页：搜索 + 今天吃什么 + 热门菜品 + 同学最近评价。
/// 首页帮助用户快速做出就餐决定，完整排行榜降级为快捷入口。
class CanteenScreen extends StatefulWidget {
  const CanteenScreen({super.key});

  @override
  State<CanteenScreen> createState() => _CanteenScreenState();
}

class _CanteenScreenState extends State<CanteenScreen> {
  final _searchCtrl = TextEditingController();
  Timer? _searchTimer;
  Map<String, dynamic>? _searchData;
  bool _searchLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<CanteenDiscoveryProvider>().loadHome();
      }
    });
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  String? get _currentQuery {
    final query = _searchCtrl.text.trim();
    return query.isEmpty ? null : query;
  }

  void _openRanking() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const CanteenRankingScreen(),
      ),
    ).then((_) {
      if (!mounted) return;
      // 返回时轻量刷新首页（评价可能已变化）。
      context.read<CanteenDiscoveryProvider>().loadHome();
    });
  }

  void _openDetail(
    int canteenId,
    String canteenName, {
    String initialImage = '',
    bool initialOffline = false,
    String? heroTag,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CanteenDetailScreen(
          canteenId: canteenId,
          canteenName: canteenName,
          initialImage: initialImage,
          initialOffline: initialOffline,
          heroTag: heroTag,
        ),
      ),
    ).then((_) {
      if (!mounted) return;
      context.read<CanteenDiscoveryProvider>().loadHome();
    });
  }

  void _openReviewComposer() {
    final hero = context.read<CanteenDiscoveryProvider>().home.hero;
    if (hero.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先加载一个商家，再发布评价')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CanteenReviewEditorScreen(
          canteenId: hero.canteenId,
          canteenName: hero.canteenName,
          canteenImage: hero.image,
          averageStar: hero.averageStar,
          ratingCount: hero.ratingCount,
          mode: CanteenReviewEditorMode.create,
          existingReview: null,
        ),
      ),
    ).then((_) {
      if (mounted) context.read<CanteenDiscoveryProvider>().loadHome();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: CanteenTheme.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '校园餐饮',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 2),
            Text(
              '同学真实评价 · 商家菜品实拍',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: CanteenTheme.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
        foregroundColor: CanteenTheme.textPrimaryColor(isDark),
        actions: [
          IconButton(
            onPressed: () => _showAddCanteenSheet(isDark),
            tooltip: '添加商家',
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(isDark),
          Expanded(child: _buildBody(isDark)),
        ],
      ),
    );
  }

  // ── Search bar ────────────────────────────────────────────────────

  Widget _buildSearchBar(bool isDark) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: CanteenTheme.surfaceBg(isDark),
            borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
            border: Border.all(color: CanteenTheme.borderColor(isDark)),
          ),
          child: TextField(
            controller: _searchCtrl,
            style: TextStyle(
              fontSize: 14,
              color: CanteenTheme.textPrimaryColor(isDark),
            ),
            decoration: InputDecoration(
              hintText: '搜索商家或菜品',
              hintStyle: TextStyle(
                fontSize: 14,
                color: CanteenTheme.textTertiaryColor(isDark),
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 20,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 40, minHeight: 40),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (value) {
              _searchTimer?.cancel();
              final query = value.trim();
              if (query.isEmpty) {
                setState(() {
                  _searchData = null;
                  _searchLoading = false;
                });
                return;
              }
              setState(() => _searchLoading = true);
              _searchTimer = Timer(const Duration(milliseconds: 240), () async {
                final provider = context.read<CanteenProvider>();
                final result = await provider.searchCanteensAndDishes(query);
                if (!mounted || _searchCtrl.text.trim() != query) return;
                if (result == null) {
                  // 旧服务端没有聚合搜索接口时降级到旧食堂列表，不影响基本发现。
                  if (provider.canteens.isEmpty && !provider.isLoading) {
                    await provider.loadCanteens();
                  }
                }
                if (!mounted || _searchCtrl.text.trim() != query) return;
                setState(() {
                  _searchData = result;
                  _searchLoading = false;
                });
              });
            },
          ),
        ),
      );

  // ── Body ──────────────────────────────────────────────────────────

  Widget _buildBody(bool isDark) {
    final query = _currentQuery?.toLowerCase();
    if (query != null) {
      return _buildSearchResults(isDark, query);
    }
    return _buildDiscoveryHome(isDark);
  }

  Widget _buildSearchResults(bool isDark, String query) {
    if (_searchLoading) return _buildSkeleton(isDark);
    if (_searchData != null) {
      return _buildServerSearchResults(isDark, query, _searchData!);
    }
    return Consumer<CanteenProvider>(
      builder: (_, provider, __) {
        if (provider.isLoading && provider.canteens.isEmpty) {
          return _buildSkeleton(isDark);
        }
        if (provider.canteens.isEmpty && provider.errorMessage != null) {
          return CanteenEmptyState(
            title: '加载失败',
            subtitle: provider.errorMessage,
            actionLabel: '重新加载',
            onAction: () => provider.loadCanteens(),
          );
        }

        final filtered = provider.canteens
            .where((c) => c.name.toLowerCase().contains(query))
            .toList();

        if (filtered.isEmpty) {
          return CanteenEmptyState(
            icon: Icons.search_off_rounded,
            title: '没有找到「$query」',
            subtitle: '这家商家还没有被收录',
            actionLabel: '提交商家',
            onAction: () => _showAddCanteenSheet(isDark, query),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            _sectionHeader(isDark, '搜索结果 (${filtered.length})'),
            for (var i = 0; i < filtered.length; i++)
              Padding(
                padding:
                    EdgeInsets.only(bottom: i == filtered.length - 1 ? 0 : 12),
                child: _buildSearchResultCard(
                  isDark,
                  filtered[i],
                  rank: provider.canteens.indexOf(filtered[i]) + 1,
                ),
              ),
            _buildListEndEntry(isDark),
          ],
        );
      },
    );
  }

  Widget _buildServerSearchResults(
      bool isDark, String query, Map<String, dynamic> data) {
    final canteens = (data['canteens'] as List?)
            ?.whereType<Map>()
            .map((item) => Canteen.fromJson(Map<String, dynamic>.from(item)))
            .toList() ??
        <Canteen>[];
    final dishes = (data['dishes'] as List?)
            ?.whereType<Map>()
            .map(
                (item) => CanteenDish.fromJson(Map<String, dynamic>.from(item)))
            .toList() ??
        <CanteenDish>[];
    if (canteens.isEmpty && dishes.isEmpty) {
      return CanteenEmptyState(
        icon: Icons.search_off_rounded,
        title: '没有找到「$query」',
        subtitle: '可以提交新的商家，或等待菜品审核通过后再搜索',
        actionLabel: '提交商家',
        onAction: () => _showAddCanteenSheet(isDark, query),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (canteens.isNotEmpty) ...[
          _sectionHeader(isDark, '商家 (${canteens.length})'),
          for (var i = 0; i < canteens.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildSearchResultCard(isDark, canteens[i], rank: i + 1),
            ),
        ],
        if (dishes.isNotEmpty) ...[
          _sectionHeader(isDark, '菜品 (${dishes.length})'),
          for (final dish in dishes) _buildDishSearchResult(isDark, dish),
        ],
      ],
    );
  }

  Widget _buildDishSearchResult(bool isDark, CanteenDish dish) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      leading: CircleAvatar(
        backgroundColor: CanteenTheme.accentSoftColor(isDark),
        child: Icon(Icons.restaurant_menu_rounded,
            color: CanteenTheme.accentStrongColor(isDark)),
      ),
      title: Text(dish.name,
          style: TextStyle(
              fontWeight: FontWeight.w700,
              color: CanteenTheme.textPrimaryColor(isDark))),
      subtitle: Text(
        dish.canteenName.isEmpty ? '菜品' : '菜品 · ${dish.canteenName}',
        style: TextStyle(color: CanteenTheme.textSecondaryColor(isDark)),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
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

  Widget _buildSearchResultCard(bool isDark, Canteen canteen,
      {required int rank}) {
    return GestureDetector(
      onTap: () => _openDetail(
        canteen.id,
        canteen.name,
        initialImage: canteen.image,
        initialOffline: canteen.isOffline,
        heroTag: 'canteen-search-${canteen.id}',
      ),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: CanteenTheme.surfaceBg(isDark),
          borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
          border: Border.all(color: CanteenTheme.borderColor(isDark)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: 'canteen-search-${canteen.id}',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
                child: SizedBox(
                  width: 80,
                  height: 76,
                  child: canteen.image.isEmpty
                      ? Container(
                          color: CanteenTheme.surfaceMutedBg(isDark),
                          alignment: Alignment.center,
                          child: Icon(Icons.restaurant_rounded,
                              size: 26,
                              color: CanteenTheme.textTertiaryColor(isDark)),
                        )
                      : CanteenStatusImage(
                          imageUrl: canteen.image,
                          variant: 'thumb',
                          offline: canteen.isOffline,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: CanteenTheme.surfaceMutedBg(isDark),
                            alignment: Alignment.center,
                            child: Icon(Icons.restaurant_rounded,
                                size: 26,
                                color: CanteenTheme.textTertiaryColor(isDark)),
                          ),
                          placeholder: (_, __) => Container(
                            color: CanteenTheme.surfaceMutedBg(isDark),
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          canteen.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: CanteenTheme.textPrimaryColor(isDark),
                          ),
                        ),
                      ),
                      if (canteen.isOffline)
                        Text(
                          '已下架',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? Colors.white60
                                : const Color(0xFF777777),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(Icons.star_rounded,
                          size: 14, color: CanteenTheme.accentColor(isDark)),
                      const SizedBox(width: 2),
                      Text(
                        canteen.averageStar > 0
                            ? canteen.averageStar.toStringAsFixed(1)
                            : '暂无评分',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: CanteenTheme.textPrimaryColor(isDark),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        canteen.ratingCount > 0
                            ? '${canteen.ratingCount} 人评价'
                            : '暂无评价',
                        style: TextStyle(
                          fontSize: 12,
                          color: CanteenTheme.textSecondaryColor(isDark),
                        ),
                      ),
                    ],
                  ),
                  if (canteen.ratingCount > 0 && !canteen.isOffline) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: CanteenTheme.accentSoftColor(isDark),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '商家排行 #$rank',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: CanteenTheme.accentStrongColor(isDark),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveryHome(bool isDark) {
    return Consumer<CanteenDiscoveryProvider>(
      builder: (_, provider, __) {
        // 首次加载：骨架
        if (provider.homeInitialLoading && !provider.hasHomeData) {
          return _buildSkeleton(isDark);
        }

        if (!provider.hasHomeData && provider.homeError != null) {
          return CanteenEmptyState(
            title: '加载失败',
            subtitle: provider.homeError,
            actionLabel: '重新加载',
            onAction: () => provider.loadHome(),
          );
        }

        final showHero = !provider.home.hero.isEmpty;
        final hotDishes = provider.home.hotDishes;
        final recentReviews = provider.home.recentReviews;

        final content = RefreshIndicator(
          onRefresh: () => provider.loadHome(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _sectionHeader(
                isDark,
                '今天吃什么',
                meta: '综合真实评分与近期反馈',
              ),
              if (showHero)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: CanteenHeroRecommendationCard(
                    hero: provider.home.hero,
                    onTap: () => _openDetail(
                      provider.home.hero.canteenId,
                      provider.home.hero.canteenName,
                      initialImage: provider.home.hero.image,
                      initialOffline:
                          provider.home.hero.operatingStatus == 'offline',
                      heroTag:
                          'canteen-home-hero-${provider.home.hero.canteenId}',
                    ),
                    heroTag:
                        'canteen-home-hero-${provider.home.hero.canteenId}',
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: _buildQuickRow(
                  isDark,
                  provider.home,
                ),
              ),
              _sectionHeader(
                isDark,
                '热门菜品',
                meta: '菜品分不混入服务评分',
              ),
              if (hotDishes.isEmpty)
                CanteenEmptyState(
                  icon: Icons.photo_camera_outlined,
                  title: '还没有菜品实拍',
                  subtitle: showHero ? '在食堂评价中关联菜品并上传实拍' : '先添加商家，再发布评价',
                  actionLabel: showHero ? '去评价并上传实拍' : '添加商家',
                  onAction: showHero
                      ? _openReviewComposer
                      : () => _showAddCanteenSheet(isDark),
                  minHeight: 150,
                )
              else
                _buildHotDishes(isDark, hotDishes),
              const SizedBox(height: 18),
              _sectionHeader(
                isDark,
                '同学最近评价',
                meta: '按可信度与新鲜度排序',
              ),
              if (recentReviews.isEmpty)
                CanteenEmptyState(
                  title: '最近还没有新的评价',
                  subtitle: '欢迎成为第一个分享用餐体验的同学',
                  actionLabel: '去评价一家商家',
                  onAction: _openReviewComposer,
                  minHeight: 150,
                )
              else
                for (var i = 0; i < recentReviews.length; i++) ...[
                  CanteenRecentReviewCard(
                    key: ValueKey(
                      '${recentReviews[i].source}:${recentReviews[i].reviewId}',
                    ),
                    review: recentReviews[i],
                    onTap: () => _openDetail(
                      recentReviews[i].canteenId,
                      recentReviews[i].canteenName,
                    ),
                  ),
                  if (i != recentReviews.length - 1) const SizedBox(height: 10),
                ],
              const SizedBox(height: 14),
              _buildListEndEntry(isDark),
            ],
          ),
        );

        // 已有数据刷新：顶部轻量进度条（stale-while-refresh）
        if (provider.homeRefreshing) {
          return Stack(
            children: [
              content,
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(),
              ),
            ],
          );
        }
        return content;
      },
    );
  }

  Widget _buildQuickRow(bool isDark, CanteenHomeData home) {
    final count = home.todayEffectiveReviewCount;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 13,
            child: CanteenRankingEntryCard(
              entry: home.rankingEntry,
              onTap: _openRanking,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 9,
            child: Container(
              key: const Key('canteen_today_review_card'),
              constraints: const BoxConstraints(minHeight: 108),
              padding: const EdgeInsets.fromLTRB(14, 14, 12, 12),
              decoration: BoxDecoration(
                color: CanteenTheme.surfaceBg(isDark),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: CanteenTheme.borderColor(isDark)),
                gradient: isDark
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFFFFFFFF), Color(0xFFFFF9EF)],
                      ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '今日新增评价',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: CanteenTheme.textPrimaryColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 26,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      color: CanteenTheme.accentStrongColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '按用户与商家去重后的今日样本',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.35,
                      color: CanteenTheme.textSecondaryColor(isDark),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHotDishes(bool isDark, List<CanteenHotDish> dishes) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: dishes.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.92,
      ),
      itemBuilder: (context, index) {
        final dish = dishes[index];
        return GestureDetector(
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
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: CanteenTheme.surfaceBg(isDark),
              borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
              border: Border.all(color: CanteenTheme.borderColor(isDark)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: dish.coverImage.isEmpty
                      ? _buildDishPlaceholder(isDark, index)
                      : CanteenStatusImage(
                          imageUrl: dish.coverImage,
                          variant: 'thumb',
                          offline: dish.isCanteenOffline,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: CanteenTheme.surfaceMutedBg(isDark),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.ramen_dining_rounded,
                              color: CanteenTheme.textTertiaryColor(isDark),
                            ),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dish.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: CanteenTheme.textPrimaryColor(isDark),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        dish.canteenName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: CanteenTheme.textTertiaryColor(isDark),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.star_rounded,
                              size: 14,
                              color: CanteenTheme.accentColor(isDark)),
                          const SizedBox(width: 2),
                          Text(
                            dish.averageScore > 0
                                ? dish.averageScore.toStringAsFixed(1)
                                : '暂无评分',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: CanteenTheme.textPrimaryColor(isDark),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${dish.reviewerCount}人评',
                            style: TextStyle(
                              fontSize: 10,
                              color: CanteenTheme.textTertiaryColor(isDark),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDishPlaceholder(bool isDark, int index) {
    const palettes = [
      [Color(0xFFF6C879), Color(0xFFF39A55)],
      [Color(0xFFF2B093), Color(0xFFE97858)],
      [Color(0xFFB9DCAE), Color(0xFF8FC696)],
      [Color(0xFFF7DC8D), Color(0xFFF2BC52)],
    ];
    const icons = [
      Icons.ramen_dining_rounded,
      Icons.lunch_dining_rounded,
      Icons.eco_rounded,
      Icons.rice_bowl_rounded,
    ];
    final palette = palettes[index % palettes.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  palette[0].withValues(alpha: 0.45),
                  palette[1].withValues(alpha: 0.55),
                ]
              : palette,
        ),
      ),
      child: Center(
        child: Icon(
          icons[index % icons.length],
          size: 48,
          color: Colors.white.withValues(alpha: 0.88),
          shadows: const [Shadow(color: Colors.black12, blurRadius: 10)],
        ),
      ),
    );
  }

  Widget _sectionHeader(bool isDark, String title, {String? meta}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 10),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: CanteenTheme.textPrimaryColor(isDark),
            ),
          ),
          const Spacer(),
          Text(
            meta ?? '信息流基于真实评价与实拍',
            style: TextStyle(
              fontSize: 11,
              color: CanteenTheme.textTertiaryColor(isDark),
            ),
          ),
        ],
      ),
    );
  }

  // 列表末尾的“提交新商家”入口
  Widget _buildListEndEntry(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Center(
        child: TextButton.icon(
          onPressed: () => _showAddCanteenSheet(isDark),
          icon: Icon(
            Icons.add_rounded,
            size: 16,
            color: CanteenTheme.accentStrongColor(isDark),
          ),
          label: Text(
            '没找到想吃的商家？提交商家',
            style: TextStyle(
              fontSize: 13,
              color: CanteenTheme.accentStrongColor(isDark),
              fontWeight: FontWeight.w700,
            ),
          ),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            minimumSize: const Size(0, 40),
          ),
        ),
      ),
    );
  }

  Widget _buildSkeleton(bool isDark) {
    final muted = CanteenTheme.surfaceMutedBg(isDark);
    Widget block({double? w, double? h}) => Container(
          width: w,
          height: h ?? 16,
          decoration: BoxDecoration(
            color: muted,
            borderRadius: BorderRadius.circular(8),
          ),
        );
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 5,
      separatorBuilder: (_, __) => const SizedBox(height: 16),
      itemBuilder: (_, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          block(w: 120),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: muted,
                  borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    block(w: 110),
                    const SizedBox(height: 10),
                    block(w: 90, h: 13),
                    const SizedBox(height: 8),
                    block(w: 130),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Add canteen sheet（沿用原逻辑，token 换为 CanteenTheme）─────────

  Future<void> _showAddCanteenSheet(bool isDark, [String? prefill]) async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先登录后提交商家')));
      return;
    }

    final nameCtrl = TextEditingController(text: prefill ?? '');
    List<String> uploadedImageUrls = [];
    var submitting = false;
    final accent = CanteenTheme.accentColor(isDark);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModalState) {
            final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
            return Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Container(
                decoration: BoxDecoration(
                  color: CanteenTheme.surfaceBg(isDark),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: CanteenTheme.borderColor(isDark),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: CanteenTheme.accentSoftColor(isDark),
                              borderRadius:
                                  BorderRadius.circular(CanteenTheme.radiusMd),
                            ),
                            child:
                                Icon(Icons.storefront_rounded, color: accent),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '提交商家',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color:
                                        CanteenTheme.textPrimaryColor(isDark),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '填写名称并上传一张商家图片',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color:
                                        CanteenTheme.textSecondaryColor(isDark),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      TextField(
                        controller: nameCtrl,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          hintText: '请输入商家名称',
                          hintStyle: TextStyle(
                            color: CanteenTheme.textSecondaryColor(isDark),
                          ),
                          prefixIcon: const Icon(Icons.restaurant_rounded),
                          filled: true,
                          fillColor: CanteenTheme.surfaceMutedBg(isDark),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(CanteenTheme.radiusMd),
                            borderSide: BorderSide(
                                color: CanteenTheme.borderColor(isDark)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(CanteenTheme.radiusMd),
                            borderSide: BorderSide(
                                color: CanteenTheme.borderColor(isDark)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(CanteenTheme.radiusMd),
                            borderSide: BorderSide(color: accent, width: 1.4),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ImageUploadWidget(
                        maxImages: 1,
                        largeCard: true,
                        emptyTitle: '添加图片',
                        emptySubtitle: '建议上传商家门面或招牌图',
                        onImagesUploaded: (images) {
                          uploadedImageUrls = images.map((e) => e.url).toList();
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: submitting
                                  ? null
                                  : () => Navigator.pop(sheetContext),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                side: BorderSide(
                                  color: CanteenTheme.borderColor(isDark),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                      CanteenTheme.radiusMd),
                                ),
                              ),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: submitting
                                  ? null
                                  : () async {
                                      final name = nameCtrl.text.trim();
                                      if (name.isEmpty) {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('请输入商家名称'),
                                          ),
                                        );
                                        return;
                                      }
                                      if (uploadedImageUrls.isEmpty) {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('请上传一张商家门面图片'),
                                          ),
                                        );
                                        return;
                                      }

                                      setModalState(() => submitting = true);
                                      final success = await context
                                          .read<CanteenProvider>()
                                          .addCanteen(
                                            name,
                                            uploadedImageUrls.first,
                                          );
                                      if (!mounted || !sheetContext.mounted) {
                                        return;
                                      }
                                      setModalState(() => submitting = false);
                                      if (success) {
                                        Navigator.pop(sheetContext);
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content:
                                                Text('已提交审核，审核通过后会显示在商家列表'),
                                          ),
                                        );
                                        await context
                                            .read<CanteenDiscoveryProvider>()
                                            .loadHome();
                                      } else {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('提交失败，请稍后重试'),
                                          ),
                                        );
                                      }
                                    },
                              style: FilledButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(48),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                      CanteenTheme.radiusMd),
                                ),
                              ),
                              child: submitting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('提交'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    nameCtrl.dispose();
  }
}
