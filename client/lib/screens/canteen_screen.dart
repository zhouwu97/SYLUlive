import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/api_constants.dart';
import '../models/canteen.dart';
import '../models/canteen_home.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_discovery_provider.dart';
import '../providers/canteen_provider.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/canteen_status_image.dart';
import '../widgets/canteen/canteen_hero_recommendation.dart';
import '../widgets/canteen/canteen_ranking_entry.dart';
import '../widgets/canteen/canteen_feed_item.dart';
import '../widgets/image_upload_widget.dart';
import 'canteen_detail_screen.dart';
import 'canteen_dish_detail_screen.dart';
import 'canteen_ranking_screen.dart';

/// 校园食堂发现首页：搜索 + 今日推荐(Hero) + 综合排行入口 + 推荐信息流。
/// 首页帮助用户回答“现在吃什么”，完整排行榜降级为二级入口。
class CanteenScreen extends StatefulWidget {
  const CanteenScreen({super.key});

  @override
  State<CanteenScreen> createState() => _CanteenScreenState();
}

class _CanteenScreenState extends State<CanteenScreen> {
  final _searchCtrl = TextEditingController();

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

  void _openDetail(int canteenId, String canteenName) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CanteenDetailScreen(
          canteenId: canteenId,
          canteenName: canteenName,
        ),
      ),
    ).then((_) {
      if (!mounted) return;
      context.read<CanteenDiscoveryProvider>().loadHome();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: CanteenTheme.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          '校园食堂',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: CanteenTheme.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
        foregroundColor: CanteenTheme.textPrimaryColor(isDark),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              '看看同学最近都在吃什么',
              style: TextStyle(
                fontSize: 12,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          ),
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
              hintText: '搜索食堂、店铺',
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
              if (value.trim().isNotEmpty) {
                final cp = context.read<CanteenProvider>();
                if (cp.canteens.isEmpty && !cp.isLoading) {
                  cp.loadCanteens();
                }
              }
              setState(() {});
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
            subtitle: '这家店还没有被收录',
            actionLabel: '提交这家店',
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

  Widget _buildSearchResultCard(bool isDark, Canteen canteen,
      {required int rank}) {
    return GestureDetector(
      onTap: () => _openDetail(canteen.id, canteen.name),
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
              tag: 'canteen-${canteen.id}',
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
                          imageUrl: ApiConstants.fullUrl(canteen.image),
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
                        '综合排行 #$rank',
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
        final feed = provider.home.feed;
        final hotDishes = provider.home.hotDishes;

        final content = RefreshIndicator(
          onRefresh: () => provider.loadHome(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (showHero)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: CanteenHeroRecommendationCard(
                    hero: provider.home.hero,
                    onTap: () => _openDetail(provider.home.hero.canteenId,
                        provider.home.hero.canteenName),
                  ),
                ),
              if (hotDishes.isNotEmpty) ...[
                _sectionHeader(isDark, '同学最近在吃'),
                _buildHotDishes(isDark, hotDishes),
                const SizedBox(height: 16),
              ],
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: CanteenRankingEntryCard(
                  entry: provider.home.rankingEntry,
                  onTap: _openRanking,
                ),
              ),
              _sectionHeader(isDark, '为你推荐'),
              if (feed.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: CanteenEmptyState(
                    title: '暂无推荐',
                    subtitle: '成为第一个收录食堂的同学吧',
                    actionLabel: '提交食堂',
                    onAction: () => _showAddCanteenSheet(isDark),
                  ),
                )
              else
                for (var i = 0; i < feed.length; i++)
                  Padding(
                    padding:
                        EdgeInsets.only(bottom: i == feed.length - 1 ? 0 : 12),
                    child: CanteenFeedItemCard(
                      key: ValueKey(feed[i].id),
                      item: feed[i],
                      onTap: () => _openDetail(
                        feed[i].canteenId,
                        feed[i].canteenName,
                      ),
                    ),
                  ),
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
                      ? Container(
                          color: CanteenTheme.surfaceMutedBg(isDark),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.ramen_dining_rounded,
                            size: 30,
                            color: CanteenTheme.textTertiaryColor(isDark),
                          ),
                        )
                      : CanteenStatusImage(
                          imageUrl: ApiConstants.fullUrl(dish.coverImage),
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

  Widget _sectionHeader(bool isDark, String title) {
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
            '信息流基于真实评价与实拍',
            style: TextStyle(
              fontSize: 11,
              color: CanteenTheme.textTertiaryColor(isDark),
            ),
          ),
        ],
      ),
    );
  }

  // 列表末尾的“提交新食堂”入口
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
            '没找到想吃的店？提交新的食堂 / 店铺',
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
          .showSnackBar(const SnackBar(content: Text('请先登录后提交食堂')));
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
                                  '提交食堂',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color:
                                        CanteenTheme.textPrimaryColor(isDark),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '填写名称并上传一张店铺图片',
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
                          hintText: '请输入食堂 / 店铺名',
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
                        emptySubtitle: '建议上传店铺门面或招牌图',
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
                                            content: Text('请输入食堂 / 店铺名'),
                                          ),
                                        );
                                        return;
                                      }
                                      if (uploadedImageUrls.isEmpty) {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('请上传一张食堂封面图片'),
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
                                            content: Text('已提交审核，审核通过后会显示在食堂页'),
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
