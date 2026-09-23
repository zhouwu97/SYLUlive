import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/admin_security_service.dart';
import '../theme/app_spacing.dart';

/// 超级管理员查看并解除当前生效的来源封禁。
class AdminSecurityBlocksScreen extends StatefulWidget {
  const AdminSecurityBlocksScreen({super.key});

  @override
  State<AdminSecurityBlocksScreen> createState() =>
      _AdminSecurityBlocksScreenState();
}

class _AdminSecurityBlocksScreenState extends State<AdminSecurityBlocksScreen> {
  List<SecurityBlockGroup> _blocks = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  AdminSecurityService get _service =>
      AdminSecurityService(context.read<AuthProvider>().dio);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final blocks = await _service.loadBlocks();
      if (!mounted) return;
      setState(() {
        _blocks = blocks;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '读取生效封禁失败';
        _loading = false;
      });
    }
  }

  Future<void> _revoke(SecurityBlockGroup block) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('解除来源封禁'),
        content: Text('将一次解除此操作的全部 ${block.routePrefixes.length} 个路由封禁。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认解除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _service.revokeBlock(block.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('封禁已解除')),
        );
        await _load();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('解除失败，请刷新后重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _remaining(DateTime expiry) {
    final duration = expiry.difference(DateTime.now());
    if (duration.isNegative) return '已到期，等待刷新';
    if (duration.inHours > 0) {
      return '剩余 ${duration.inHours} 小时 ${duration.inMinutes % 60} 分钟';
    }
    return '剩余 ${duration.inMinutes + 1} 分钟';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('当前生效封禁')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Text(
              '校园网、宿舍和运营商出口可能由多人共用。误封时请及时解除。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Center(
                child: Column(children: [
                  Text(_error!),
                  TextButton(onPressed: _load, child: const Text('重试')),
                ]),
              )
            else if (_blocks.isEmpty)
              const Center(child: Text('当前没有生效封禁'))
            else
              for (final block in _blocks)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('来源 ${block.sourceFingerprint}',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: AppSpacing.sm),
                          Text(_remaining(block.expiresAt)),
                          Text(
                              '作用域：${block.routePrefixes.map((value) => value.isEmpty ? '全部高风险接口' : value).join('、')}'),
                          if (block.reason.isNotEmpty)
                            Text('原因：${block.reason}'),
                          Text('创建人：管理员 ${block.createdBy}'),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: _busy ? null : () => _revoke(block),
                              child: const Text('解除封禁'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
