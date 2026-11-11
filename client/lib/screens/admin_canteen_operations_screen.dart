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
import '../widgets/canteen/canteen_theme.dart';

/// 管理员食堂运营操作：下架/恢复营业与历史状态展示。
class AdminCanteenOperationsScreen extends StatefulWidget {
  const AdminCanteenOperationsScreen({super.key});

  @override
  State<AdminCanteenOperationsScreen> createState() =>
      _AdminCanteenOperationsScreenState();
}

class _AdminCanteenOperationsScreenState
    extends State<AdminCanteenOperationsScreen> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await context.read<CanteenProvider>().loadCanteens();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _offline(Canteen canteen) async {
    final controller = TextEditingController();
    final reason = await showAppDialog<String>(
      context: context,
      builder: (dialogContext) => AppAlertDialog(
        title: Text('下架「${canteen.name}」'),
        content: TextField(
          controller: controller,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '请输入下架原因（可选）',
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
    final result = await context
        .read<CanteenProvider>()
        .offlineCanteen(canteen.id, reason: reason);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result == null ? '下架失败' : '已下架，历史数据保留')),
    );
    if (result != null) await _load();
  }

  Future<void> _online(Canteen canteen) async {
    final result =
        await context.read<CanteenProvider>().onlineCanteen(canteen.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result == null ? '恢复营业失败' : '已恢复营业')),
    );
    if (result != null) await _load();
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
      context.read<CanteenDiscoveryProvider>().invalidateRanking();
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
      discovery.loadRanking(sort: discovery.rankingSort),
    ]);
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: _buildPage);

  Widget _buildPage(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<CanteenProvider>();
    return Scaffold(
      backgroundColor:
          AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
      appBar: AppBar(
        title: const Text('食堂运营'),
        backgroundColor:
            AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
        foregroundColor: CanteenTheme.textPrimaryColor(isDark),
      ),
      body: _loading && provider.canteens.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : provider.errorMessage != null && provider.canteens.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(provider.errorMessage!),
                  TextButton(onPressed: _load, child: const Text('重试'))
                ]))
              : provider.canteens.isEmpty
                  ? Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('暂无店铺'),
                      TextButton(onPressed: _load, child: const Text('刷新'))
                    ]))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        addRepaintBoundaries: false,
                        padding: const EdgeInsets.all(16),
                        itemCount: provider.canteens.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, index) {
                          final canteen = provider.canteens[index];
                          return AppCardSurface(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: CanteenTheme.surfaceBg(isDark),
                              borderRadius:
                                  BorderRadius.circular(CanteenTheme.radiusMd),
                              border: Border.all(
                                  color: CanteenTheme.borderColor(isDark)),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(canteen.name,
                                          style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color:
                                                  CanteenTheme.textPrimaryColor(
                                                      isDark))),
                                      const SizedBox(height: 4),
                                      Text(
                                        canteen.locationLabel.isEmpty
                                            ? '位置未设置'
                                            : canteen.locationLabel,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      Text(
                                        canteen.isOffline
                                            ? '已下架（历史数据保留）'
                                            : '营业中',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: canteen.isOffline
                                              ? CanteenTheme.textSecondaryColor(
                                                  isDark)
                                              : CanteenTheme.accentStrongColor(
                                                  isDark),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: '管理「${canteen.name}」',
                                  icon: const Icon(Icons.more_vert_rounded),
                                  onSelected: (action) {
                                    switch (action) {
                                      case 'edit':
                                        _edit(canteen);
                                      case 'dishes':
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                AdminCanteenDishesScreen(
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
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Text('修改名称和位置'),
                                    ),
                                    PopupMenuItem(
                                      value: 'dishes',
                                      child: Text('菜品管理'),
                                    ),
                                    PopupMenuItem(
                                      value: 'tags',
                                      child: Text('修改店铺标签'),
                                    ),
                                  ],
                                ),
                                canteen.isOffline
                                    ? OutlinedButton(
                                        onPressed: () => _online(canteen),
                                        child: const Text('恢复营业'),
                                      )
                                    : OutlinedButton(
                                        onPressed: () => _offline(canteen),
                                        child: const Text('下架'),
                                      ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
