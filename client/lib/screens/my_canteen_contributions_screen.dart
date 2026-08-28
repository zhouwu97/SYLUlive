import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/api_constants.dart';
import '../providers/canteen_provider.dart';
import '../services/idempotency_key.dart';
import '../widgets/app_page_app_bar.dart';
import '../widgets/canteen/canteen_empty_state.dart';
import '../widgets/canteen/canteen_status_image.dart';
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
  bool _loadFailed = false;
  String? _loadError;
  List<Map<String, dynamic>> _items = const [];
  final Map<String, String> _retryIdempotencyKeys = <String, String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  Future<void> _reload() async {
    final provider = context.read<CanteenProvider>();
    if (mounted && _items.isEmpty) setState(() => _loading = true);
    final items = await provider.loadMyCanteenContributions();
    if (!mounted) return;
    setState(() {
      if (items != null) {
        _items = items;
        _loadFailed = false;
        _loadError = null;
      } else {
        _loadFailed = true;
        _loadError = provider.errorMessage ?? '贡献记录加载失败，请重试';
      }
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
            : _loadFailed && _items.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 170),
                      CanteenEmptyState(
                        minHeight: 160,
                        icon: Icons.cloud_off_rounded,
                        title: '贡献记录加载失败',
                        subtitle: _loadError ?? '请检查网络后重试',
                        actionLabel: '重新加载',
                        onAction: _reload,
                      ),
                    ],
                  )
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
                        itemCount: _items.length + (_loadFailed ? 1 : 0),
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, index) {
                          if (_loadFailed && index == 0) {
                            return _buildLoadErrorBanner(isDark);
                          }
                          final itemIndex = _loadFailed ? index - 1 : index;
                          return _buildItem(_items[itemIndex], isDark);
                        },
                      ),
      ),
    );
  }

  Widget _buildLoadErrorBanner(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: CanteenTheme.surfaceMutedBg(isDark),
        borderRadius: BorderRadius.circular(CanteenTheme.radiusSm),
        border: Border.all(color: CanteenTheme.borderColor(isDark)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded,
              size: 18, color: CanteenTheme.textTertiaryColor(isDark)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _loadError ?? '最新贡献加载失败，当前显示的是上次记录',
              style: TextStyle(
                fontSize: 12,
                color: CanteenTheme.textSecondaryColor(isDark),
              ),
            ),
          ),
          TextButton(onPressed: _reload, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildItem(Map<String, dynamic> item, bool isDark) {
    final status = item['status']?.toString() ?? 'pending';
    final reason = item['reject_reason']?.toString() ?? '';
    final image = item['image']?.toString() ?? '';
    final isPhoto = item['type'] == 'dish_photo';
    final mergedName = item['merged_into_dish_name']?.toString().trim() ?? '';
    final statusLabel = switch (status) {
      'approved' || 'active' => '已通过',
      'rejected' => '未通过',
      'archived' => '已归档',
      'merged' => mergedName.isEmpty ? '已合并' : '已合并至「$mergedName」',
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
              child: CanteenStatusImage(
                imageUrl: image,
                variant: 'thumb',
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
                if (status == 'rejected' || status == 'archived') ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _retryContribution(item),
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: Text(isPhoto ? '重新提交实拍' : '重新提交菜品'),
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
    final provider = context.read<CanteenProvider>();
    if (item['type'] == 'dish_photo') {
      final fileId = (item['file_id'] as num?)?.toInt() ?? 0;
      if (fileId > 0) {
        final key = 'photo:${item['photo_id'] ?? fileId}';
        final message = await provider.submitDishSubmission(
          canteenId,
          dishId: dishId,
          dishName: item['dish_name']?.toString(),
          fileId: fileId,
          idempotencyKey: _retryIdempotencyKeys[key] ??=
              newIdempotencyKey('canteen-dish-photo-retry'),
        );
        if (!mounted) return;
        if (message != null) {
          _retryIdempotencyKeys.remove(key);
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(message)));
          await _reload();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(provider.errorMessage ?? '提交失败，请稍后重试')),
          );
        }
        return;
      }
    } else {
      final key = 'dish:$dishId';
      final success = await provider.resubmitDish(
        dishId,
        idempotencyKey: _retryIdempotencyKeys[key] ??=
            newIdempotencyKey('canteen-dish-retry'),
      );
      if (!mounted) return;
      if (success) {
        _retryIdempotencyKeys.remove(key);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('菜品已重新提交审核')),
        );
        await _reload();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(provider.errorMessage ?? '提交失败，请稍后重试')),
        );
      }
    }
  }
}
