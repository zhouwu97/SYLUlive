import 'package:shenliyuan/widgets/app_dialog.dart';
import '../widgets/app_card.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/app_page_background.dart';
import '../providers/canteen_discovery_provider.dart';
import 'admin_canteen_dishes_screen.dart';
import 'admin_canteen_tags_dialog.dart';
import '../models/canteen.dart';
import '../providers/canteen_provider.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_ranking_filter.dart' show canteenFilterPill;
import '../widgets/canteen/canteen_status_image.dart';
import '../widgets/canteen/canteen_theme.dart';

/// 管理员食堂运营：按营业状态查看全部已收录商家，下架/恢复营业，
/// 以及修改名称位置、菜品管理和店铺标签。
///
/// 下架不删除数据：商家退出“现有商家”排名、首页推荐和搜索，“全部排名”仍保留；
/// 其评价、图片和投票对普通用户变为只读，只有管理员可以处理。
class AdminCanteenOperationsScreen extends StatefulWidget {
  const AdminCanteenOperationsScreen({super.key});

  @override
  State<AdminCanteenOperationsScreen> createState() =>
      _AdminCanteenOperationsScreenState();
}

enum _StatusFilter { all, active, offline }

class _AdminCanteenOperationsScreenState
    extends State<AdminCanteenOperationsScreen> {
  bool _loading = true;
  String? _error;
  List<Canteen> _canteens = const [];
  _StatusFilter _filter = _StatusFilter.all;
  String _query = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    final provider = context.read<CanteenProvider>();
    final items = await provider.adminListCanteens();
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      if (items == null) {
        _error = provider.errorMessage ?? '商家列表加载失败，请重试';
      } else {
        _canteens = items;
      }
    });
  }

  /// 状态变化会影响首页推荐和两种排行，统一失效后刷新。
  void _invalidateDiscovery() {
    context.read<CanteenDiscoveryProvider?>()?.invalidateRanking();
  }

  Future<void> _offline(Canteen canteen) async {
    final controller = TextEditingController();
    final reason = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text('下架「${canteen.name}」'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _ConsequenceList(items: [
                '不再参与现有商家排名，其余商家名次顺延；“全部排名”中保留并标注已下架',
                '不出现在首页推荐、热门菜品和搜索结果里',
                '评价、图片和投票对同学只读，只有管理员可以处理',
                '数据全部保留，随时可以恢复营业',
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '下架原因（可选，仅管理员可见），如：档口转让、停业装修',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('确认下架'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || !mounted) return;
    final provider = context.read<CanteenProvider>();
    final result = await provider.offlineCanteen(canteen.id, reason: reason);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result == null
          ? provider.errorMessage ?? '下架失败，请稍后重试'
          : '「${canteen.name}」已下架，内容转为只读'),
    ));
    if (result != null) {
      _invalidateDiscovery();
      await _load();
    }
  }

  Future<void> _online(Canteen canteen) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text('恢复「${canteen.name}」营业'),
        content: const _ConsequenceList(items: [
          '重新参与现有商家排名、首页推荐和搜索',
          '同学可以继续发布、修改评价和投票',
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复营业'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final provider = context.read<CanteenProvider>();
    final result = await provider.onlineCanteen(canteen.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result == null
          ? provider.errorMessage ?? '恢复营业失败，请稍后重试'
          : '「${canteen.name}」已恢复营业'),
    ));
    if (result != null) {
      _invalidateDiscovery();
      await _load();
    }
  }

  Future<void> _edit(Canteen canteen) async {
    final provider = context.read<CanteenProvider>();
    await provider.loadMeta();
    if (!mounted) return;
    final nameController = TextEditingController(text: canteen.name);
    var area = canteen.locationArea;
    var floor = canteen.locationFloor;
    final saved = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Widget choices(
            String label,
            List<String> options,
            String selected,
            ValueChanged<String> onSelected,
          ) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: Theme.of(dialogContext).textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final option in options)
                      ChoiceChip(
                        label: Text(option),
                        selected: selected == option,
                        onSelected: (_) =>
                            setDialogState(() => onSelected(option)),
                      ),
                  ],
                ),
              ],
            );
          }

          return AppAlertDialog(
            title: const Text('修改商家信息'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    maxLength: 100,
                    decoration: const InputDecoration(labelText: '商家名称'),
                  ),
                  choices('所在食堂', provider.locationAreas, area,
                      (value) => area = value),
                  const SizedBox(height: 12),
                  choices('楼层', provider.locationFloors, floor,
                      (value) => floor = value),
                  const SizedBox(height: 12),
                  const Text(
                    '已有评价、菜品和实拍都会保留在这家店下。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    final name = nameController.text.trim();
    nameController.dispose();
    if (saved != true || !mounted) return;
    if (name.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('商家名称至少 2 个字')),
      );
      return;
    }
    final changedName = name != canteen.name ? name : null;
    final changedArea = area != canteen.locationArea ? area : null;
    final changedFloor = floor != canteen.locationFloor ? floor : null;
    if (changedName == null && changedArea == null && changedFloor == null) {
      return;
    }
    final ok = await provider.adminUpdateCanteen(
      canteen.id,
      name: changedName,
      locationArea: changedArea,
      locationFloor: changedFloor,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '商家信息已更新' : provider.errorMessage ?? '修改失败，请稍后重试'),
    ));
    if (ok) {
      _invalidateDiscovery();
      await _load();
    }
  }

  Future<void> _editTags(Canteen canteen) async {
    final saved = await showAppDialog<bool>(
      context: context,
      builder: (_) => AdminCanteenTagsDialog(canteen: canteen),
    );
    if (!mounted || saved != true) return;
    final discovery = context.read<CanteenDiscoveryProvider>();
    discovery.invalidateRanking();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('店铺标签已保存')),
    );
    await Future.wait([
      _load(),
      discovery.loadHome(),
      discovery.loadRanking(
          sort: discovery.rankingSort, scope: discovery.rankingScope),
    ]);
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  List<Canteen> get _visible {
    final query = _query.toLowerCase();
    return _canteens.where((canteen) {
      final statusOk = switch (_filter) {
        _StatusFilter.all => true,
        _StatusFilter.active => !canteen.isOffline,
        _StatusFilter.offline => canteen.isOffline,
      };
      return statusOk &&
          (query.isEmpty ||
              canteen.name.toLowerCase().contains(query) ||
              canteen.locationLabel.contains(query));
    }).toList(growable: false);
  }

  Widget _buildPage(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
      appBar: AppBar(
        title: const Text('食堂运营'),
        backgroundColor:
            AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
        foregroundColor: CanteenTheme.textPrimaryColor(isDark),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              onChanged: (value) => setState(() => _query = value.trim()),
              decoration: InputDecoration(
                hintText: '搜索商家名称或位置',
                prefixIcon: const Icon(Icons.search_rounded),
                isDense: true,
                filled: true,
                fillColor: CanteenTheme.surfaceMutedBg(isDark),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(CanteenTheme.radiusMd),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          _buildFilterRow(isDark),
          Expanded(child: _buildBody(isDark)),
        ],
      ),
    );
  }

  Widget _buildFilterRow(bool isDark) {
    final offline = _canteens.where((canteen) => canteen.isOffline).length;
    final active = _canteens.length - offline;
    Widget pill(_StatusFilter filter, String label) => canteenFilterPill(
          isDark,
          label: label,
          selected: _filter == filter,
          onTap: () => setState(() => _filter = filter),
        );
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        children: [
          pill(_StatusFilter.all, '全部 ${_canteens.length}'),
          const SizedBox(width: 8),
          pill(_StatusFilter.active, '营业中 $active'),
          const SizedBox(width: 8),
          pill(_StatusFilter.offline, '已下架 $offline'),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading && _canteens.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _canteens.isEmpty) {
      return CanteenEmptyState(
        title: '加载失败',
        subtitle: _error,
        actionLabel: '重新加载',
        onAction: _load,
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return CanteenEmptyState(
        icon: Icons.storefront_outlined,
        title: _canteens.isEmpty ? '暂无已收录商家' : '没有符合条件的商家',
        actionLabel: '刷新',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        addRepaintBoundaries: false,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        itemCount: visible.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, index) => _buildCanteenCard(isDark, visible[index]),
      ),
    );
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  Widget _buildCanteenCard(bool isDark, Canteen canteen) {
    final offline = canteen.isOffline;
    final stats = [
      canteen.ratingCount > 0
          ? '${canteen.averageStar.toStringAsFixed(1)} 分 · ${canteen.ratingCount} 人评价'
          : '暂无评价',
      '${canteen.dishCount} 道菜',
    ].join(' · ');
    return AppCardSurface(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusLg),
        border: Border.all(color: CanteenTheme.borderColor(isDark)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: canteen.image.isEmpty
                      ? _thumbPlaceholder(isDark)
                      : CanteenStatusImage(
                          imageUrl: canteen.image,
                          variant: 'thumb',
                          offline: offline,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              _thumbPlaceholder(isDark),
                          placeholder: (_, __) => _thumbPlaceholder(isDark),
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
                        Flexible(
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
                        const SizedBox(width: 6),
                        _StatusPill(offline: offline, isDark: isDark),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      canteen.locationLabel.isEmpty
                          ? '位置未设置'
                          : canteen.locationLabel,
                      style: TextStyle(
                        fontSize: 12,
                        color: CanteenTheme.textSecondaryColor(isDark),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      stats,
                      style: TextStyle(
                        fontSize: 12,
                        color: CanteenTheme.textTertiaryColor(isDark),
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '管理「${canteen.name}」',
                icon: Icon(Icons.more_horiz_rounded,
                    color: CanteenTheme.textSecondaryColor(isDark)),
                onSelected: (action) {
                  switch (action) {
                    case 'edit':
                      _edit(canteen);
                    case 'dishes':
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AdminCanteenDishesScreen(
                            canteenId: canteen.id,
                            canteenName: canteen.name,
                          ),
                        ),
                      );
                    case 'tags':
                      _editTags(canteen);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('修改名称和位置')),
                  PopupMenuItem(value: 'dishes', child: Text('菜品管理')),
                  PopupMenuItem(value: 'tags', child: Text('修改店铺标签')),
                ],
              ),
            ],
          ),
          if (offline) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(
                color: CanteenTheme.surfaceMutedBg(isDark),
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
              ),
              child: Text(
                [
                  canteen.offlinedAt == null
                      ? '已下架'
                      : '${_formatDate(canteen.offlinedAt!)} 下架',
                  canteen.offlineReason.trim().isEmpty
                      ? '未填写原因'
                      : '原因：${canteen.offlineReason.trim()}',
                  '内容对同学只读',
                ].join(' · '),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: CanteenTheme.textSecondaryColor(isDark),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Align(
              alignment: Alignment.centerRight,
              child: offline
                  ? FilledButton.icon(
                      onPressed: () => _online(canteen),
                      icon: const Icon(Icons.storefront_rounded, size: 16),
                      label: const Text('恢复营业'),
                      style: FilledButton.styleFrom(
                        backgroundColor: CanteenTheme.accentColor(isDark),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 36),
                      ),
                    )
                  : OutlinedButton.icon(
                      onPressed: () => _offline(canteen),
                      icon: const Icon(Icons.block_rounded, size: 16),
                      label: const Text('下架商家'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: BorderSide(
                            color: Colors.redAccent.withValues(alpha: 0.5)),
                        minimumSize: const Size(0, 36),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumbPlaceholder(bool isDark) => Container(
        color: CanteenTheme.surfaceMutedBg(isDark),
        alignment: Alignment.center,
        child: Icon(Icons.storefront_rounded,
            size: 22, color: CanteenTheme.textTertiaryColor(isDark)),
      );
}

class _StatusPill extends StatelessWidget {
  final bool offline;
  final bool isDark;

  const _StatusPill({required this.offline, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: offline
            ? CanteenTheme.surfaceMutedBg(isDark)
            : CanteenTheme.accentSoftColor(isDark),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        offline ? '已下架' : '营业中',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: offline
              ? CanteenTheme.textSecondaryColor(isDark)
              : CanteenTheme.accentStrongColor(isDark),
        ),
      ),
    );
  }
}

/// 下架 / 恢复营业确认框里的影响说明。
class _ConsequenceList extends StatelessWidget {
  final List<String> items;

  const _ConsequenceList({required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 7, right: 8),
                  child: Icon(Icons.circle, size: 5),
                ),
                Expanded(
                  child: Text(item,
                      style: const TextStyle(fontSize: 13, height: 1.45)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
