import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/canteen_discovery_provider.dart';
import '../providers/canteen_provider.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/canteen_hero_recommendation.dart';
import '../widgets/canteen/canteen_ranking_entry.dart';
import '../widgets/canteen/canteen_feed_item.dart';
import '../widgets/image_upload_widget.dart';
import 'canteen_detail_screen.dart';
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
            onChanged: (value) => setState(() {}),
          ),
        ),
      );

  // ── Body ──────────────────────────────────────────────────────────

  Widget _buildBody(bool isDark) {
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

        final query = _currentQuery?.toLowerCase();

        // 搜索：过滤 feed 里的食堂/标签，保留服务端 rank（不显示假排名）。
        final filteredFeed = query == null
            ? provider.home.feed
            : provider.home.feed
                .where((f) =>
                    f.canteenName.toLowerCase().contains(query) ||
                    f.dishName.toLowerCase().contains(query) ||
                    f.tags.any((t) => t.toLowerCase().contains(query)) ||
                    f.title.toLowerCase().contains(query))
                .toList();

        final showHero = query == null && !provider.home.hero.isEmpty;
        final showRankingEntry = query == null;

        if (query != null && filteredFeed.isEmpty) {
          return CanteenEmptyState(
            icon: Icons.search_off_rounded,
            title: '没有找到「$query」',
            subtitle: '这家店还没有被收录',
            actionLabel: '提交这家店',
            onAction: () => _showAddCanteenSheet(isDark, query),
          );
        }

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
                    onTap: () => _openDetail(
                        provider.home.hero.canteenId,
                        provider.home.hero.canteenName),
                  ),
                ),
              if (showRankingEntry)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: CanteenRankingEntryCard(
                    entry: provider.home.rankingEntry,
                    onTap: _openRanking,
                  ),
                ),
              if (showHero || showRankingEntry)
                _sectionHeader(isDark, query == null ? '为你推荐' : '搜索「$query」'),
              if (filteredFeed.isEmpty)
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
                for (var i = 0; i < filteredFeed.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                        bottom: i == filteredFeed.length - 1 ? 0 : 12),
                    child: CanteenFeedItemCard(
                      key: ValueKey(filteredFeed[i].id),
                      item: filteredFeed[i],
                      onTap: () => _openDetail(
                        filteredFeed[i].canteenId,
                        filteredFeed[i].canteenName,
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
                                      setModalState(
                                          () => submitting = false);
                                      if (success) {
                                        Navigator.pop(sheetContext);
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                                '已提交审核，审核通过后会显示在食堂页'),
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
