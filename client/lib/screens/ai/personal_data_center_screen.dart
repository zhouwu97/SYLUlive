import 'package:shenliyuan/widgets/app_dialog.dart';
import '../../widgets/app_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../widgets/app_page_background.dart';
import '../../features/ai_runtime/tool_calling/tool_permission.dart';
import '../../features/ai_device_bridge/device_credential_store.dart';
import '../../features/campus_data/erke/erke_repository.dart';
import '../../features/campus_data/storage/account_cache_namespace.dart';
import '../../features/campus_data/storage/account_scoped_snapshot_store.dart';
import '../../features/campus_data/storage/erke_cache_store.dart';
import '../../features/campus_data/storage/personal_snapshot_models.dart';
import '../../features/personal_data_sync/personal_data_sync_coordinator.dart';
import '../../features/personal_data_sync/personal_data_sync_models.dart';
import '../../features/personal_data_sync/personal_data_sync_result.dart';
import '../../features/personal_data_sync/erke_snapshot_upload.dart';
import '../../providers/edu_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/publish_session_scope.dart';
import '../../services/webvpn_service.dart';
import '../../services/physical_credential_store.dart';
import '../../utils/app_feedback.dart';
import '../../theme/app_spacing.dart';
import '../../widgets/erke_snapshot_upload_dialog.dart';
import 'campus_personal_data_permission_screen.dart';

class PersonalDataCenterScreen extends StatefulWidget {
  const PersonalDataCenterScreen({
    super.key,
    required this.appUserId,
    required this.sourceAccountId,
    required this.dio,
  });

  final String appUserId;
  final String sourceAccountId;
  final Dio dio;

  @override
  State<PersonalDataCenterScreen> createState() =>
      _PersonalDataCenterScreenState();
}

class _PersonalDataCenterScreenState extends State<PersonalDataCenterScreen> {
  late Future<List<_VaultStatus>> _statuses;
  bool _isSyncing = false;
  bool _clearing = false;
  PublishSessionScope? _session;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.read<AuthProvider>();
    if (_session == null &&
        auth.isLoggedIn &&
        auth.user?.id.toString() == widget.appUserId) {
      _session = PublishSessionScope(
          accountId: auth.user!.id,
          accountSessionEpoch: auth.accountSessionEpoch);
    }
  }

  bool _owns() {
    if (!mounted || _session == null) return false;
    final auth = context.read<AuthProvider>();
    return auth.isLoggedIn &&
        _session!.owns(
            userId: auth.user?.id, sessionEpoch: auth.accountSessionEpoch) &&
        context.read<EduProvider>().studentId == widget.sourceAccountId;
  }

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
            isStale: (snapshot?.isStale ?? false) ||
                snapshot?.payload['isPartial'] == true,
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
    if (!_owns()) return;
    final store = AesGcmAccountScopedSnapshotStore(appUserId: widget.appUserId);
    await store.clearUser();
    if (!_owns()) return;
    await LocalToolAuditStore(
      accountFingerprint: AccountCacheNamespace.fingerprint(widget.appUserId),
    ).clear();
    if (!_owns()) return;
    await DeviceCredentialStore().deleteErke(widget.sourceAccountId);
    if (!_owns()) return;
    await PhysicalCredentialStore().delete(widget.sourceAccountId);
    if (mounted) setState(() => _statuses = _load());
  }

  Future<void> _clearAll() async {
    if (!_owns()) return;
    await AesGcmAccountScopedSnapshotStore.clearAllVaultData();
    if (!_owns()) return;
    await DeviceCredentialStore().deleteErke(widget.sourceAccountId);
    if (!_owns()) return;
    await PhysicalCredentialStore().delete(widget.sourceAccountId);
    if (mounted) setState(() => _statuses = _load());
  }

  Future<void> _syncPersonalData() async {
    if (_isSyncing || _clearing || !_owns()) return;
    setState(() => _isSyncing = true);
    final vpn = WebVpnService();
    try {
      final coordinator = PersonalDataSyncCoordinator(
        isCurrent: _owns,
        academicGateway: EduProviderPersonalAcademicSyncGateway(
          context.read<EduProvider>(),
        ),
        erkeGateway: ErkeRepositoryPersonalSyncGateway(
          repository: ErkeRepository(
            isCurrent: _owns,
            vpnService: vpn,
            cacheStore: ErkeCacheStore(
              appUserId: widget.appUserId,
              sourceAccountId: widget.sourceAccountId,
            ),
          ),
          requestCredentials: _requestErkeCredentials,
          snapshotUploader:
              ErkeSnapshotUploadGateway(widget.dio, session: _session!),
          isCurrent: _owns,
          uploadPolicyStore: PreferenceErkeSnapshotUploadPolicyStore(
            appUserId: widget.appUserId,
          ),
          requestUploadPolicy: _requestErkeSnapshotUploadPolicy,
        ),
      );
      final result = await coordinator.sync(
        datasets: const <PersonalSyncDataset>{
          PersonalSyncDataset.schedule,
          PersonalSyncDataset.grades,
          PersonalSyncDataset.academicSituation,
          PersonalSyncDataset.creditRequirements,
          PersonalSyncDataset.erke,
        },
        trigger: PersonalSyncTrigger.vault,
      );
      if (!mounted || !_owns()) return;
      final successful = result.items.values
          .where((item) => item.status == PersonalSyncItemStatus.success)
          .length;
      final erkeMessage = result.items[PersonalSyncDataset.erke]?.message;
      AppFeedback.success(
        '已更新 $successful/${result.items.length} 项个人数据'
        '${erkeMessage == null ? '' : '。$erkeMessage'}',
        context: context,
      );
      setState(() => _statuses = _load());
    } finally {
      vpn.dispose();
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  Future<PersonalErkeCredentials?> _requestErkeCredentials() async {
    final saved =
        await DeviceCredentialStore().readErke(widget.sourceAccountId);
    if (!mounted || !_owns()) return null;
    if (saved != null) {
      return PersonalErkeCredentials(
        studentId: widget.sourceAccountId,
        casPassword: saved.casPassword,
        erkePassword: saved.erkePassword,
      );
    }
    final casController = TextEditingController();
    final erkeController = TextEditingController();
    try {
      return await showDialog<PersonalErkeCredentials>(
        context: context,
        builder: (dialogContext) => AppAlertDialog(
          title: const Text('更新二课数据'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: casController,
                obscureText: true,
                decoration: const InputDecoration(labelText: '统一认证密码'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: erkeController,
                obscureText: true,
                decoration: const InputDecoration(labelText: '二课查询密码'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final casPassword = casController.text;
                final erkePassword = erkeController.text;
                if (casPassword.isEmpty || erkePassword.isEmpty) return;
                Navigator.pop(
                  dialogContext,
                  PersonalErkeCredentials(
                    studentId: widget.sourceAccountId,
                    casPassword: casPassword,
                    erkePassword: erkePassword,
                  ),
                );
              },
              child: const Text('更新'),
            ),
          ],
        ),
      );
    } finally {
      casController.dispose();
      erkeController.dispose();
    }
  }

  Future<ErkeSnapshotUploadPolicy?> _requestErkeSnapshotUploadPolicy() {
    if (!_owns()) return Future.value(null);
    return showErkeSnapshotUploadDialog(context);
  }

  Future<void> _deleteUploadedErkeSnapshot() async {
    try {
      if (!_owns()) return;
      await ErkeSnapshotUploadGateway(widget.dio, session: _session!).delete();
      if (mounted) {
        AppFeedback.success('已删除服务端二课快照', context: context);
      }
    } on ErkeSnapshotUploadException catch (error) {
      if (mounted) {
        AppFeedback.error(error.message, context: context);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AppPageBackground(
      builder: (context) => Consumer2<AuthProvider, EduProvider>(
            builder: (context, auth, edu, _) => _owns()
                ? _buildPageWithBackground(context)
                : Scaffold(
                    appBar: AppBar(title: const Text('个人数据保险箱')),
                    body: const Center(child: Text('登录状态或教务身份已变化，请返回后重新打开'))),
          ));

  Widget _buildPageWithBackground(BuildContext context) {
    final appFingerprint = AccountCacheNamespace.fingerprint(widget.appUserId);
    final sourceFingerprint =
        AccountCacheNamespace.fingerprint(widget.sourceAccountId);
    return Scaffold(
      appBar: AppBar(title: const Text('个人数据保险箱')),
      body: AppContentSurface(
          child: FutureBuilder<List<_VaultStatus>>(
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
              const AppCardDivider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: const Text('校园 Agent 数据权限'),
                subtitle: const Text('管理服务器使用个人数据的长期授权'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CampusPersonalDataPermissionScreen(
                      dio: widget.dio,
                    ),
                  ),
                ),
              ),
              const AppCardDivider(),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isSyncing || _clearing ? null : _syncPersonalData,
                  icon: _isSyncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(_isSyncing ? '更新中' : '更新个人数据'),
                ),
              ),
              const SizedBox(height: 8),
              ...snapshot.data!.map(_statusTile),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _isSyncing || _clearing
                    ? null
                    : () => _confirm(
                          '删除已上传二课快照？',
                          _deleteUploadedErkeSnapshot,
                        ),
                icon: const Icon(Icons.cloud_off_outlined),
                label: const Text('删除已上传二课快照'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _isSyncing || _clearing
                    ? null
                    : () => _confirm('清除当前账号数据？', _clearCurrent),
                icon: const Icon(Icons.delete_outline),
                label: const Text('清除当前账号数据'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _isSyncing || _clearing
                    ? null
                    : () => _confirm('清除全部本地个人数据？', _clearAll),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('清除全部本地个人数据'),
              ),
            ],
          );
        },
      )),
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
    if (_isSyncing || _clearing || !_owns()) return;
    setState(() => _clearing = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AppAlertDialog(
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
      if (confirmed == true && _owns()) await action();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
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
