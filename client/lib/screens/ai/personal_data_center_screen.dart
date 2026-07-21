import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../features/ai_runtime/tool_calling/tool_permission.dart';
import '../../features/campus_data/storage/account_cache_namespace.dart';
import '../../features/campus_data/storage/account_scoped_snapshot_store.dart';
import '../../features/campus_data/storage/personal_snapshot_models.dart';

class PersonalDataCenterScreen extends StatefulWidget {
  const PersonalDataCenterScreen({
    super.key,
    required this.appUserId,
    required this.sourceAccountId,
  });

  final String appUserId;
  final String sourceAccountId;

  @override
  State<PersonalDataCenterScreen> createState() =>
      _PersonalDataCenterScreenState();
}

class _PersonalDataCenterScreenState extends State<PersonalDataCenterScreen> {
  late Future<List<_VaultStatus>> _statuses;

  @override
  void initState() {
    super.initState();
    _statuses = _load();
  }

  Future<List<_VaultStatus>> _load() async {
    if (widget.appUserId.trim().isEmpty ||
        widget.sourceAccountId.trim().isEmpty) {
      return snapshotBackedPersonalDataTypes
          .map((type) => _VaultStatus(type: type))
          .toList();
    }
    final store = AesGcmAccountScopedSnapshotStore(appUserId: widget.appUserId);
    final result = <_VaultStatus>[];
    for (final type in snapshotBackedPersonalDataTypes) {
      final source = switch (type) {
        PersonalDataType.academic || PersonalDataType.schedule => 'edu',
        PersonalDataType.physical => 'physical',
        PersonalDataType.erke => 'erke',
        PersonalDataType.studentProfile => throw StateError('基础画像不属于保险箱快照'),
      };
      try {
        final snapshot = await store.read(
          type: type,
          sourceSystem: source,
          sourceAccountId: widget.sourceAccountId,
        );
        result.add(
          _VaultStatus(
            type: type,
            fetchedAt: snapshot?.fetchedAt,
            isStale: snapshot?.isStale ?? false,
            schemaVersion: snapshot?.schemaVersion,
          ),
        );
      } catch (_) {
        result.add(_VaultStatus(type: type, corrupted: true));
      }
    }
    return result;
  }

  Future<void> _clearCurrent() async {
    final store = AesGcmAccountScopedSnapshotStore(appUserId: widget.appUserId);
    await store.clearUser();
    await LocalToolAuditStore(
      accountFingerprint: AccountCacheNamespace.fingerprint(widget.appUserId),
    ).clear();
    if (mounted) setState(() => _statuses = _load());
  }

  Future<void> _clearAll() async {
    await AesGcmAccountScopedSnapshotStore.clearAllVaultData();
    if (mounted) setState(() => _statuses = _load());
  }

  @override
  Widget build(BuildContext context) {
    final appFingerprint = AccountCacheNamespace.fingerprint(widget.appUserId);
    final sourceFingerprint =
        AccountCacheNamespace.fingerprint(widget.sourceAccountId);
    return Scaffold(
      appBar: AppBar(title: const Text('个人数据保险箱')),
      body: FutureBuilder<List<_VaultStatus>>(
        future: _statuses,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('当前账号'),
                subtitle: Text('App $appFingerprint · 来源 $sourceFingerprint'),
              ),
              const Divider(),
              ...snapshot.data!.map(_statusTile),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => _confirm('清除当前账号数据？', _clearCurrent),
                icon: const Icon(Icons.delete_outline),
                label: const Text('清除当前账号数据'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => _confirm('清除全部本地个人数据？', _clearAll),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('清除全部本地个人数据'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _statusTile(_VaultStatus status) {
    final label = switch (status.type) {
      PersonalDataType.schedule => '课表',
      PersonalDataType.academic => '成绩',
      PersonalDataType.physical => '体测',
      PersonalDataType.erke => '二课',
      PersonalDataType.studentProfile => '学生基础画像',
    };
    final state = status.corrupted
        ? '密文校验失败'
        : status.fetchedAt == null
            ? '未同步'
            : status.isStale
                ? '已过期'
                : '已同步';
    final time = status.fetchedAt == null
        ? ''
        : ' · ${DateFormat('yyyy-MM-dd HH:mm').format(status.fetchedAt!.toLocal())}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        status.corrupted ? Icons.error_outline : Icons.shield_outlined,
      ),
      title: Text(label),
      subtitle: Text('$state$time'),
      trailing: status.schemaVersion == null
          ? null
          : Text('v${status.schemaVersion}'),
    );
  }

  Future<void> _confirm(String title, Future<void> Function() action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: const Text('删除后需要重新同步，操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await action();
  }
}

class _VaultStatus {
  const _VaultStatus({
    required this.type,
    this.fetchedAt,
    this.isStale = false,
    this.schemaVersion,
    this.corrupted = false,
  });
  final PersonalDataType type;
  final DateTime? fetchedAt;
  final bool isStale;
  final int? schemaVersion;
  final bool corrupted;
}
