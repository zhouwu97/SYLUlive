import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../providers/canteen_provider.dart';
import 'canteen_dish_detail_screen.dart' show showDishPhotoUploadSheet;
import '../widgets/app_page_app_bar.dart';
import '../widgets/canteen/canteen_theme.dart';

/// 食堂贡献追踪页：菜品候选和实拍共享服务端状态，不与评价列表混在一起。
class MyCanteenContributionsScreen extends StatefulWidget {
  const MyCanteenContributionsScreen({super.key});

  @override
  State<MyCanteenContributionsScreen> createState() =>
      _MyCanteenContributionsScreenState();
}

class _MyCanteenContributionsScreenState
    extends State<MyCanteenContributionsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final items =
        await context.read<CanteenProvider>().loadMyCanteenContributions();
    if (!mounted) return;
    setState(() {
      _items = items ?? const [];
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: CanteenTheme.pageBg(isDark),
      appBar: const AppPageAppBar(title: Text('我的食堂贡献')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 220),
                      Center(child: Text('还没有菜品或实拍贡献')),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, index) =>
                        _buildItem(_items[index], isDark),
                  ),
      ),
    );
  }

  Widget _buildItem(Map<String, dynamic> item, bool isDark) {
    final status = item['status']?.toString() ?? 'pending';
    final reason = item['reject_reason']?.toString() ?? '';
    final image = item['image']?.toString() ?? '';
    final isPhoto = item['type'] == 'dish_photo';
    final statusLabel = switch (status) {
      'approved' || 'active' => '已通过',
      'rejected' => '未通过',
      'archived' => '已归档',
      _ => '审核中',
    };
    final statusColor = status == 'rejected'
        ? Colors.redAccent
        : status == 'approved' || status == 'active'
            ? Colors.green
            : CanteenTheme.accentColor(isDark);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
        border: Border.all(color: CanteenTheme.borderColor(isDark)),
      ),
      child: Row(
        children: [
          if (image.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
              child: CachedNetworkImage(
                imageUrl: ApiConstants.fullUrl(image),
                width: 60,
                height: 60,
                fit: BoxFit.cover,
              ),
            )
          else
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: CanteenTheme.surfaceMutedBg(isDark),
                borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
              ),
              child: Icon(Icons.restaurant_outlined,
                  color: CanteenTheme.textTertiaryColor(isDark)),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${item['dish_name'] ?? '未命名菜品'}${isPhoto ? ' · 实拍' : ''}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: CanteenTheme.textPrimaryColor(isDark),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item['canteen_name']?.toString() ?? '',
                  style: TextStyle(
                    fontSize: 12,
                    color: CanteenTheme.textSecondaryColor(isDark),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  children: [
                    Text(statusLabel,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: statusColor)),
                    if (reason.isNotEmpty)
                      Text('原因：$reason',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.redAccent)),
                  ],
                ),
                if (status == 'rejected') ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _retryContribution(item),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('重新提交实拍'),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _retryContribution(Map<String, dynamic> item) async {
    final canteenId = (item['canteen_id'] as num?)?.toInt() ?? 0;
    final dishId = (item['dish_id'] as num?)?.toInt() ?? 0;
    if (canteenId <= 0 || dishId <= 0) return;
    final success = await showDishPhotoUploadSheet(
      context,
      canteenId: canteenId,
      dishId: dishId,
      dishName: item['dish_name']?.toString(),
      provider: context.read<CanteenProvider>(),
    );
    if (success == true && mounted) await _reload();
  }
}
