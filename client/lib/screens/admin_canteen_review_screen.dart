import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../theme/app_colors.dart';
import '../widgets/app_page_app_bar.dart';
import '../widgets/canteen/canteen_pending_card.dart';

/// 管理员食堂审核页：待审核食堂提交列表 + 通过/驳回。
class AdminCanteenReviewScreen extends StatefulWidget {
  const AdminCanteenReviewScreen({super.key});

  @override
  State<AdminCanteenReviewScreen> createState() =>
      _AdminCanteenReviewScreenState();
}

class _AdminCanteenReviewScreenState extends State<AdminCanteenReviewScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _isLoading = true;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _loadFailed = false;
    });
    final items =
        await context.read<CanteenProvider>().adminListPendingCanteens();
    if (!mounted) return;
    if (items == null) {
      setState(() {
        _loadFailed = true;
        _items = [];
        _isLoading = false;
      });
      return;
    }
    setState(() {
      _items = items;
      _isLoading = false;
    });
    await _resolveCreatorNames();
  }

  /// 兼容未上线 creator_name 的服务端：用 /user/:id 补全提交人昵称。
  Future<void> _resolveCreatorNames() async {
    final missingIds = <int>{};
    for (final item in _items) {
      final name = (item['creator_name'] ?? '').toString();
      final createdBy = (item['created_by'] as num?)?.toInt() ?? 0;
      if (name.isEmpty && createdBy != 0) missingIds.add(createdBy);
    }
    if (missingIds.isEmpty) return;

    final dio = context.read<AuthProvider>().dio;
    final names = <int, String>{};
    await Future.wait(missingIds.map((id) async {
      try {
        final res = await dio.get('/user/$id');
        final data = res.data;
        final nickname = (data is Map ? data['nickname']?.toString() : null);
        if (nickname != null && nickname.isNotEmpty) {
          names[id] = nickname;
        }
      } catch (_) {
        // 单个用户解析失败不影响列表展示
      }
    }));
    if (!mounted || names.isEmpty) return;
    setState(() {
      for (final item in _items) {
        final createdBy = (item['created_by'] as num?)?.toInt() ?? 0;
        final name = (item['creator_name'] ?? '').toString();
        if (name.isEmpty && names.containsKey(createdBy)) {
          item['creator_name'] = names[createdBy];
        }
      }
    });
  }

  Future<void> _approve(Map<String, dynamic> item) async {
    final id = (item['id'] as num?)?.toInt() ?? 0;
    if (id == 0) return;
    final message =
        await context.read<CanteenProvider>().adminApproveCanteen(id);
    if (!mounted) return;
    if (message != null) {
      setState(() => _items.removeWhere((i) => i['id'] == id));
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('操作失败，请稍后重试')),
      );
    }
  }

  Future<void> _reject(Map<String, dynamic> item) async {
    final id = (item['id'] as num?)?.toInt() ?? 0;
    if (id == 0) return;
    final name = (item['name'] ?? '').toString();

    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text('驳回「$name」？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('驳回后该食堂提交将被删除，提交者会收到通知。'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '驳回原因（选填）',
                  hintText: '例如：名称重复、信息不完整',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确认驳回'),
            ),
          ],
        );
      },
    );
    if (reason == null || !mounted) return;

    final success = await context
        .read<CanteenProvider>()
        .adminRejectCanteen(id, reason: reason);
    if (!mounted) return;
    if (success) {
      setState(() => _items.removeWhere((i) => i['id'] == id));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已驳回')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('驳回失败，请稍后重试')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    Widget body;
    if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_loadFailed) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('加载待审核食堂失败'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _load,
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: _items.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                children: [_buildEmptyState(isDark)],
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                itemCount: _items.length,
                itemBuilder: (context, index) =>
                    _buildCard(_items[index], isDark),
              ),
      );
    }

    return Scaffold(
      appBar: const AppPageAppBar(title: Text('食堂审核')),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.brandPrimary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.storefront,
              color: AppColors.brandPrimary,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无待审核食堂',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : AppColors.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '新的商家提交会出现在这里',
            style: TextStyle(
              fontSize: 13,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.62)
                  : AppColors.textSecondaryLight,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> canteen, bool isDark) {
    return CanteenPendingCard(
      canteen: canteen,
      isDark: isDark,
      onApprove: () => _approve(canteen),
      onReject: () => _reject(canteen),
    );
  }
}
