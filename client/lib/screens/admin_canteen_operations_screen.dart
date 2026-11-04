import 'package:shenliyuan/widgets/app_dialog.dart';
import '../widgets/app_card.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../widgets/app_page_background.dart';
import '../providers/canteen_discovery_provider.dart';
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
                                IconButton(
                                  tooltip: '修改店铺标签',
                                  icon: const Icon(Icons.label_outline),
                                  onPressed: () async {
                                    final saved = await showAppDialog<bool>(
                                      context: context,
                                      builder: (_) => AdminCanteenTagsDialog(
                                          canteen: canteen),
                                    );
                                    if (!mounted || saved != true) return;
                                    final discovery = this
                                        .context
                                        .read<CanteenDiscoveryProvider>();
                                    discovery.invalidateRanking();
                                    ScaffoldMessenger.of(this.context)
                                        .showSnackBar(
                                      const SnackBar(content: Text('店铺标签已保存')),
                                    );
                                    await Future.wait([
                                      _load(),
                                      discovery.loadHome(),
                                      discovery.loadRanking(
                                          sort: discovery.rankingSort),
                                    ]);
                                  },
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
