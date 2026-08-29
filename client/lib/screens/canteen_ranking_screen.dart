import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/canteen_ranking.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_discovery_provider.dart';
import '../providers/canteen_provider.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_theme.dart';
import '../widgets/canteen/canteen_ranking_item.dart';
import '../widgets/canteen/canteen_ranking_filter.dart';
import 'canteen_detail_screen.dart';

/// 完整排行榜：综合排序 / 评分优先 / 评价人数。
/// rank 由服务端返回；同时展示原始星级、评价人数与综合分，便于用户理解。
/// 热度排序待热度统计上线后再开放。
class CanteenRankingScreen extends StatefulWidget {
  const CanteenRankingScreen({super.key});

  @override
  State<CanteenRankingScreen> createState() => _CanteenRankingScreenState();
}

class _CanteenRankingScreenState extends State<CanteenRankingScreen> {
  String _sort = CanteenRankingSort.composite;
  String _locationArea = '';
  String _locationFloor = '';

  /// 位置筛选（'' = 不限）：区域与楼层组合生效。
  List<CanteenRankingItem> _applyLocationFilter(List<CanteenRankingItem> items) {
    return items
        .where((item) => canteenRankingItemMatchesLocation(
            item, _locationArea, _locationFloor))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<CanteenDiscoveryProvider>().loadRanking(sort: _sort);
      }
    });
  }

  void _switchSort(String sort) {
    if (sort == _sort) return;
    setState(() => _sort = sort);
    context.read<CanteenDiscoveryProvider>().loadRanking(sort: sort);
  }

  void _showExplanation(bool isDark) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: CanteenTheme.surfaceBg(isDark),
        title: Text(
          '综合排序是怎么算的？',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: CanteenTheme.textPrimaryColor(isDark),
          ),
        ),
        content: const Text(
          '综合排序采用贝叶斯加权评分，既看平均星级、也看评价人数：评分越高、人数越多越靠前；'
          '评价很少的高分商家会向全校平均分收缩，避免“5人/1人”虚高霸榜。\n\n'
          '“评分优先”只按星级排，样本很少时会标注“样本较少”；'
          '“评价人数”按参与评价的人数排序。\n\n'
          '菜品和实拍数量仅供参考，不参与综合分计算。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              '知道了',
              style: TextStyle(
                color: CanteenTheme.accentStrongColor(isDark),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openDetail(CanteenRankingItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CanteenDetailScreen(
          canteenId: item.id,
          canteenName: item.name,
          dishCount: item.dishCount,
          dishWithPhotoCount: item.dishWithPhotoCount,
          dishPhotoCount: item.dishPhotoCount,
          initialImage: item.image,
          initialOffline: item.isOffline,
          heroTag: 'canteen-ranking-${item.id}',
        ),
      ),
    );
  }

  Future<void> _confirmDelete(CanteenRankingItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除商家'),
        content: Text('确定要删除商家 "${item.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final success =
        await context.read<CanteenProvider>().deleteCanteen(item.id);
    if (success && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('删除成功')));
      context.read<CanteenDiscoveryProvider>().invalidateRanking();
      context.read<CanteenDiscoveryProvider>().loadRanking(sort: _sort);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: CanteenTheme.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          '商家排行',
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
          CanteenRankingFilterBar(
            selected: _sort,
            onChanged: _switchSort,
            locationArea: _locationArea,
            locationFloor: _locationFloor,
            onLocationFilterChanged: (area, floor) =>
                setState(() {
                  _locationArea = area;
                  _locationFloor = floor;
                }),
          ),
          _buildExplanationLine(isDark),
          const SizedBox(height: 4),
          Expanded(child: _buildList(isDark)),
        ],
      ),
    );
  }

  Widget _buildExplanationLine(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '综合分兼顾评分与评价人数，降低少量评价带来的排名波动',
              style: TextStyle(
                fontSize: 11,
                color: CanteenTheme.textTertiaryColor(isDark),
              ),
            ),
          ),
          GestureDetector(
            onTap: () => _showExplanation(isDark),
            child: Icon(
              Icons.info_outline_rounded,
              size: 15,
              color: CanteenTheme.textTertiaryColor(isDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(bool isDark) {
    final user = context.watch<AuthProvider>().user;
    final isAdmin = user?.role == 'admin' || user?.role == 'super_admin';

    return Consumer<CanteenDiscoveryProvider>(
      builder: (_, provider, __) {
        final items = _applyLocationFilter(provider.rankingItems);

        if (provider.rankingLoading && items.isEmpty) {
          return _buildSkeleton(isDark);
        }
        if (!provider.rankingLoading &&
            items.isEmpty &&
            provider.rankingError != null) {
          return CanteenEmptyState(
            title: '加载失败',
            subtitle: provider.rankingError,
            actionLabel: '重新加载',
            onAction: () => provider.loadRanking(sort: _sort),
          );
        }
        if (items.isEmpty) {
          final hasLocationFilter =
              _locationArea.isNotEmpty || _locationFloor.isNotEmpty;
          if (hasLocationFilter && provider.rankingItems.isNotEmpty) {
            return CanteenEmptyState(
              title: '该位置暂无商家',
              subtitle: '试试切换其他食堂或楼层',
              actionLabel: '查看全部商家',
              onAction: () => setState(() {
                _locationArea = '';
                _locationFloor = '';
              }),
            );
          }
          return CanteenEmptyState(
            title: '暂无商家',
            subtitle: '成为第一个收录商家的同学吧',
            actionLabel: '返回餐饮页添加',
            onAction: () => Navigator.pop(context),
          );
        }

        return RefreshIndicator(
          onRefresh: () => provider.loadRanking(sort: _sort),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: items.length,
            itemBuilder: (_, index) {
              final item = items[index];
              return CanteenRankingItemTile(
                item: item,
                onTap: () => _openDetail(item),
                onLongPress: isAdmin ? () => _confirmDelete(item) : null,
              );
            },
          ),
        );
      },
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 4,
      separatorBuilder: (_, __) => const SizedBox(height: 18),
      itemBuilder: (_, __) => Row(
        children: [
          block(w: 24, h: 18),
          const SizedBox(width: 12),
          Container(
            width: 96,
            height: 88,
            decoration: BoxDecoration(
              color: muted,
              borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                block(w: 120),
                const SizedBox(height: 10),
                block(w: 96, h: 13),
                const SizedBox(height: 8),
                block(w: 140),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
