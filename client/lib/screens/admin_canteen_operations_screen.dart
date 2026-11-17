import 'package:shenliyuan/widgets/app_dialog.dart';
import '../widgets/app_card.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/app_page_background.dart';
import '../providers/canteen_discovery_provider.dart';
import 'admin_canteen_dishes_screen.dart';
import 'admin_canteen_editor_screen.dart';
import 'admin_canteen_review_screen.dart';
import 'canteen_submit_screen.dart';
import '../services/publish_session_scope.dart';
import '../models/canteen.dart';
import '../providers/canteen_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_status_image.dart';
import '../widgets/canteen/canteen_theme.dart';

/// 食堂管理的统一入口：投稿、审核、资料与标签编辑、菜品和营业状态。
///
/// 下架不删除数据：商家退出全部排名、首页推荐和搜索，进入独立怀旧版块；
/// 其评价、图片和投票只读，只有超级管理员可以维护食堂资料。
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
  final _searchController = TextEditingController();
  String _areaFilter = '';
  final _busyIds = <int>{};
  late final AuthProvider? _auth;
  late final PublishSessionScope? _scope;

  bool get _sessionValid =>
      _auth?.user?.isAdmin == true &&
      _scope!.owns(
          userId: _auth!.user?.id, sessionEpoch: _auth!.accountSessionEpoch);

  bool _canManage(Canteen canteen) =>
      _sessionValid &&
      !_busyIds.contains(canteen.id) &&
      (!canteen.isOffline || _auth?.user?.role == 'super_admin');

  @override
  void initState() {
    super.initState();
    _auth = context.read<AuthProvider?>();
    _scope = _auth == null
        ? null
        : PublishSessionScope(
            accountId: _auth!.user?.id ?? 0,
            accountSessionEpoch: _auth!.accountSessionEpoch,
          );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _sessionValid) {
        context.read<CanteenProvider>().loadMeta();
        _load();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_sessionValid) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    final provider = context.read<CanteenProvider>();
    final items = await provider.adminListCanteens();
    if (!mounted || !_sessionValid || generation != _generation) return;
    setState(() {
      _loading = false;
      if (items == null) {
        _error = provider.errorMessage ?? '商家列表加载失败，请重试';
      } else {
        _canteens = items;
      }
    });
  }

  /// 状态变化会影响首页推荐和排行，统一失效后刷新。
  void _invalidateDiscovery() {
    context.read<CanteenDiscoveryProvider?>()?.invalidateRanking();
  }

  Future<void> _offline(Canteen canteen) =>
      _changeStatus(canteen, offline: true);
  Future<void> _online(Canteen canteen) =>
      _changeStatus(canteen, offline: false);

  Future<void> _changeStatus(Canteen canteen, {required bool offline}) async {
    if (!_canManage(canteen)) return;
    setState(() => _busyIds.add(canteen.id));
    var reason = '';
    try {
      final confirmedReason = await showAppDialog<String>(
        context: context,
        builder: (dialogContext) => AppAlertDialog(
          title:
              Text(offline ? '下架「${canteen.name}」' : '恢复「${canteen.name}」营业'),
          content: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ConsequenceList(
                  items: offline
                      ? const [
                          '不再参与任何排名，移入独立怀旧版块，其余商家名次顺延',
                          '不出现在首页推荐、热门菜品和搜索结果里',
                          '评价、图片和投票只读，仅超级管理员可维护食堂资料或恢复营业',
                          '数据全部保留，随时可以恢复营业',
                        ]
                      : const [
                          '重新参与现有商家排名、首页推荐和搜索',
                          '同学可以继续发布、修改评价和投票',
                        ]),
              if (offline) ...[
                const SizedBox(height: 12),
                TextField(
                  onChanged: (value) => reason = value,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '下架原因（可选）',
                    hintText: '如：档口转让、停业装修，仅管理员可见',
                  ),
                ),
              ],
            ],
          )),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, reason),
              child: Text(offline ? '确认下架' : '恢复营业'),
            ),
          ],
        ),
      );
      if (confirmedReason == null ||
          !mounted ||
          !_sessionValid ||
          (canteen.isOffline && _auth?.user?.role != 'super_admin')) {
        return;
      }
      final provider = context.read<CanteenProvider>();
      final result = offline
          ? await provider.offlineCanteen(canteen.id,
              reason: confirmedReason, sessionScope: _scope)
          : await provider.onlineCanteen(canteen.id, sessionScope: _scope);
      if (!mounted || !_sessionValid) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result == null
            ? provider.errorMessage ?? '操作失败，请稍后重试'
            : offline
                ? '「${canteen.name}」已下架，内容转为只读'
                : '「${canteen.name}」已恢复营业'),
      ));
      if (result != null) {
        _invalidateDiscovery();
        await _load();
        if (mounted && _sessionValid) {
          context.read<CanteenDiscoveryProvider?>()?.loadHome();
        }
      }
    } finally {
      if (mounted) setState(() => _busyIds.remove(canteen.id));
    }
  }

  Future<void> _edit(Canteen canteen) async {
    if (!_canManage(canteen)) return;
    final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => AdminCanteenEditorScreen(canteen: canteen),
        ));
    if (!mounted || !_sessionValid || saved != true) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('商家资料与展示标签已保存')),
    );
    _invalidateDiscovery();
    await _load();
    if (mounted && _sessionValid) {
      context.read<CanteenDiscoveryProvider?>()?.loadHome();
    }
  }

  Future<void> _openSubpage(Widget page) async {
    if (!_sessionValid) return;
    final result = await Navigator.push<Object?>(
        context, MaterialPageRoute(builder: (_) => page));
    if (!mounted || !_sessionValid) return;
    if (result == true && page is CanteenSubmitScreen) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已提交审核，可在「我的食堂贡献」查看进度'),
      ));
    }
    _invalidateDiscovery();
    await _load();
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  List<Canteen> get _matching {
    final query = _query.toLowerCase();
    return _canteens
        .where((canteen) =>
            (_areaFilter.isEmpty ||
                (_areaFilter == '未设置'
                    ? canteen.locationArea.isEmpty
                    : canteen.locationArea == _areaFilter)) &&
            (query.isEmpty ||
                canteen.name.toLowerCase().contains(query) ||
                canteen.locationLabel.toLowerCase().contains(query)))
        .toList(growable: false);
  }

  List<Canteen> get _visible {
    return _matching.where((canteen) {
      final statusOk = switch (_filter) {
        _StatusFilter.all => true,
        _StatusFilter.active => !canteen.isOffline,
        _StatusFilter.offline => canteen.isOffline,
      };
      return statusOk;
    }).toList(growable: false);
  }

  Widget _buildPage(BuildContext context) {
    context.watch<AuthProvider?>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background =
        AppPageBackground.color(context, CanteenTheme.surfaceBg(dark));
    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        title: Text('食堂管理', style: Theme.of(context).textTheme.titleMedium),
        backgroundColor: background,
        actions: [
          TextButton(
              onPressed: _sessionValid
                  ? () => _openSubpage(const AdminCanteenReviewScreen())
                  : null,
              child: const Text('审核')),
          IconButton(
              tooltip: '提交商家',
              icon: const Icon(Icons.add),
              onPressed: _sessionValid
                  ? () => _openSubpage(const CanteenSubmitScreen())
                  : null),
          IconButton(
              tooltip: '刷新商家列表',
              icon: const Icon(Icons.refresh),
              onPressed: _sessionValid && !_loading ? _load : null),
        ],
      ),
      body: !_sessionValid
          ? const CanteenEmptyState(
              title: '需要管理员权限', subtitle: '账号或管理权限已变更，请返回后重新进入')
          : Center(
              child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: RefreshIndicator(
                onRefresh: _load,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  slivers: [
                    SliverToBoxAdapter(
                        child: Column(children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) =>
                              setState(() => _query = value.trim()),
                          decoration: InputDecoration(
                            hintText: '搜索商家名称或位置',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清除搜索',
                                    icon: const Icon(Icons.close, size: 20),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _query = '');
                                    },
                                  ),
                            filled: true,
                            fillColor: CanteenTheme.surfaceMutedBg(dark),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none),
                          ),
                        ),
                      ),
                      _buildFilterRow(),
                      const Divider(height: 1),
                      if (_loading && _canteens.isNotEmpty)
                        const LinearProgressIndicator(),
                      if (_error != null && _canteens.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(children: [
                            Expanded(
                                child: Text('刷新失败，保留上次列表。$_error',
                                    style:
                                        Theme.of(context).textTheme.bodySmall)),
                            TextButton(
                                onPressed: _load, child: const Text('重试')),
                          ]),
                        ),
                    ])),
                    _buildBody(dark),
                  ],
                ),
              ),
            )),
    );
  }

  Widget _buildFilterRow() {
    final matching = _matching;
    final offline = matching.where((canteen) => canteen.isOffline).length;
    final scheme = Theme.of(context).colorScheme;
    Widget tab(_StatusFilter filter, String label) => DecoratedBox(
          decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      width: 2,
                      color: _filter == filter
                          ? scheme.primary
                          : Colors.transparent))),
          child: TextButton(
            onPressed: () => setState(() => _filter = filter),
            style: TextButton.styleFrom(
              foregroundColor:
                  _filter == filter ? scheme.primary : scheme.onSurfaceVariant,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: const RoundedRectangleBorder(),
            ),
            child: Text(label),
          ),
        );
    final areas = context.watch<CanteenProvider>().locationAreas;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(children: [
        Expanded(
            child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  tab(_StatusFilter.all, '全部 ${matching.length}'),
                  tab(_StatusFilter.active, '营业中 ${matching.length - offline}'),
                  tab(_StatusFilter.offline, '已下架 $offline'),
                ]))),
        PopupMenuButton<String>(
          tooltip: '区域筛选',
          initialValue: _areaFilter,
          onSelected: (value) => setState(() => _areaFilter = value),
          itemBuilder: (_) => [
            for (final area in ['', ...areas, '未设置'])
              CheckedPopupMenuItem(
                  value: area,
                  checked: area == _areaFilter,
                  child: Text(area.isEmpty ? '全部区域' : area)),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_areaFilter.isEmpty ? '全部区域' : _areaFilter,
                  style: Theme.of(context).textTheme.bodySmall),
              const Icon(Icons.expand_more, size: 18),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildBody(bool dark) {
    if (_loading && _canteens.isEmpty) {
      return const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()));
    }
    if (_error != null && _canteens.isEmpty) {
      return SliverFillRemaining(
          hasScrollBody: false,
          child: CanteenEmptyState(
              title: '加载失败',
              subtitle: _error,
              actionLabel: '重新加载',
              onAction: _load));
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return SliverFillRemaining(
          hasScrollBody: false,
          child: CanteenEmptyState(
            title: _canteens.isEmpty ? '暂无已收录商家' : '没有符合条件的商家',
            actionLabel: _canteens.isEmpty ? '刷新' : '清除筛选',
            onAction: _canteens.isEmpty
                ? _load
                : () => setState(() {
                      _searchController.clear();
                      _query = '';
                      _areaFilter = '';
                      _filter = _StatusFilter.all;
                    }),
          ));
    }
    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 24),
      sliver: SliverList.separated(
        addRepaintBoundaries: false,
        itemCount: visible.length,
        separatorBuilder: (_, __) => const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Divider(height: 1)),
        itemBuilder: (_, index) => _buildCanteenRow(dark, visible[index]),
      ),
    );
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  Widget _buildCanteenRow(bool dark, Canteen canteen) {
    final offline = canteen.isOffline;
    final canManage =
        _sessionValid && (!offline || _auth?.user?.role == 'super_admin');
    final busy = _busyIds.contains(canteen.id);
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final stats = [
      canteen.ratingCount > 0
          ? '${canteen.averageStar.toStringAsFixed(1)} 分 · ${canteen.ratingCount} 人评价'
          : '暂无评价',
      '${canteen.dishCount} 道菜',
    ].join(' · ');
    return AppContentSurface(
        child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
              width: 48,
              height: 48,
              child: canteen.image.isEmpty
                  ? _thumbPlaceholder(dark)
                  : CanteenStatusImage(
                      imageUrl: canteen.image,
                      variant: 'thumb',
                      offline: offline,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _thumbPlaceholder(dark),
                      placeholder: (_, __) => _thumbPlaceholder(dark))),
        ),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(canteen.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            Text(
                busy
                    ? '处理中…'
                    : offline
                        ? '已下架'
                        : '营业中',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: secondary)),
          ]),
          const SizedBox(height: 4),
          Text(canteen.locationLabel.isEmpty ? '位置未设置' : canteen.locationLabel,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: secondary)),
          const SizedBox(height: 2),
          Text(stats,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: secondary)),
          if (offline)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  [
                    if (canteen.offlinedAt != null)
                      '${_formatDate(canteen.offlinedAt!)} 下架',
                    if (canteen.offlineReason.trim().isNotEmpty)
                      '原因：${canteen.offlineReason.trim()}',
                    '仅超级管理员可维护',
                  ].join(' · '),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: secondary)),
            ),
        ])),
        if (canManage)
          PopupMenuButton<String>(
            enabled: !busy,
            tooltip: '管理「${canteen.name}」',
            icon: Icon(Icons.more_horiz, color: secondary),
            onSelected: (action) {
              switch (action) {
                case 'edit':
                  _edit(canteen);
                case 'dishes':
                  _openSubpage(AdminCanteenDishesScreen(
                      canteenId: canteen.id, canteenName: canteen.name));
                case 'status':
                  offline ? _online(canteen) : _offline(canteen);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('编辑商家')),
              const PopupMenuItem(value: 'dishes', child: Text('菜品管理')),
              PopupMenuItem(
                  value: 'status', child: Text(offline ? '恢复营业' : '下架商家')),
            ],
          ),
      ]),
    ));
  }

  Widget _thumbPlaceholder(bool dark) => ColoredBox(
        color: CanteenTheme.surfaceMutedBg(dark),
        child: Icon(Icons.storefront_outlined,
            size: 22, color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
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
