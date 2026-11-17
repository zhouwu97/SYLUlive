import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/canteen.dart';
import '../providers/canteen_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/app_card.dart';
import '../widgets/app_page_background.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_status_image.dart';
import '../widgets/canteen/canteen_theme.dart';
import 'canteen_detail_screen.dart';
import 'admin_canteen_operations_screen.dart';

/// 下架食堂的独立存档；按下架时间展示，不显示名次或综合排行分。
class CanteenNostalgiaScreen extends StatefulWidget {
  const CanteenNostalgiaScreen({super.key});

  @override
  State<CanteenNostalgiaScreen> createState() => _CanteenNostalgiaScreenState();
}

class _CanteenNostalgiaScreenState extends State<CanteenNostalgiaScreen> {
  List<Canteen> _items = const [];
  bool _loading = true;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items =
          await context.read<CanteenProvider>().loadNostalgiaCanteens();
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '怀旧食堂加载失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Scaffold(
          backgroundColor:
              AppPageBackground.color(context, CanteenTheme.pageBg(isDark)),
          appBar: AppBar(title: const Text('怀旧食堂'), actions: [
            if (context.watch<AuthProvider>().user?.role == 'super_admin')
              TextButton(
                onPressed: () async {
                  await Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              const AdminCanteenOperationsScreen()));
                  if (mounted) await _load();
                },
                child: const Text('维护资料'),
              ),
          ]),
          body: Column(children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('那些年吃过的味道。已下架食堂不参与排名，历史评价与图片只读保留，仅超级管理员可维护食堂资料。'),
            ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Expanded(child: Text(_error!, semanticsLabel: _error)),
                  TextButton(onPressed: _load, child: const Text('重试'))
                ]),
              ),
            Expanded(
                child: _items.isEmpty
                    ? _loading
                        ? const Center(child: CircularProgressIndicator())
                        : CanteenEmptyState(
                            title: _error == null ? '暂时没有怀旧食堂' : '加载失败',
                            subtitle: _error ?? '下架后的食堂会保存在这里',
                            actionLabel: '重新加载',
                            onAction: _load,
                          )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16),
                          itemCount: _items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            return AppCardSurface(
                                child: ListTile(
                              leading: SizedBox(
                                  width: 56,
                                  height: 56,
                                  child: CanteenStatusImage(
                                    imageUrl: item.image,
                                    offline: true,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, __, ___) =>
                                        const Icon(Icons.storefront_outlined),
                                    placeholder: (_, __) =>
                                        const Icon(Icons.storefront_outlined),
                                  )),
                              title: Text(item.name),
                              subtitle: Text([
                                item.locationLabel,
                                '已下架 · 只读存档',
                                if (item.ratingCount > 0)
                                  '历史评分 ${item.averageStar.toStringAsFixed(1)} · ${item.ratingCount} 人评价',
                              ].where((s) => s.isNotEmpty).join('\n')),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () async {
                                await Navigator.push<void>(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => CanteenDetailScreen(
                                              canteenId: item.id,
                                              canteenName: item.name,
                                              initialImage: item.image,
                                              initialOffline: true,
                                            )));
                                if (mounted) await _load();
                              },
                            ));
                          },
                        ))),
          ]),
        );
      });
}
