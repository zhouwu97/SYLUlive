import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../services/ai_personal_data_permission_service.dart';
import '../../utils/app_feedback.dart';

/// 配置校园 Agent 跨会话访问个人数据时的长期授权偏好。
class CampusPersonalDataPermissionScreen extends StatefulWidget {
  const CampusPersonalDataPermissionScreen({super.key, required this.dio});

  final Dio dio;

  @override
  State<CampusPersonalDataPermissionScreen> createState() =>
      _CampusPersonalDataPermissionScreenState();
}

class _CampusPersonalDataPermissionScreenState
    extends State<CampusPersonalDataPermissionScreen> {
  late final AiPersonalDataPermissionService _service;
  late Future<
          Map<AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>>
      _permissions;
  AiPersonalDataPermissionScope? _savingScope;
  String? _accountUserId;
  bool _hasLoadedForAccount = false;
  AuthProvider? _authProvider;

  @override
  void initState() {
    super.initState();
    _service = AiPersonalDataPermissionService(widget.dio);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authProvider = context.watch<AuthProvider>();
    if (_authProvider == authProvider) return;

    _authProvider?.removeListener(_handleAuthChanged);
    _authProvider = authProvider;
    _authProvider!.addListener(_handleAuthChanged);
    _reloadForAccount(authProvider.user?.id.toString());
  }

  void _handleAuthChanged() {
    if (!mounted) return;
    _reloadForAccount(_authProvider?.user?.id.toString());
  }

  void _reloadForAccount(String? userId) {
    if (_hasLoadedForAccount && userId == _accountUserId) return;
    // 切换账号后必须丢弃旧账号的权限快照，避免短暂展示错误的授权状态。
    _hasLoadedForAccount = true;
    _accountUserId = userId;
    _savingScope = null;
    _permissions = _load();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _authProvider?.removeListener(_handleAuthChanged);
    super.dispose();
  }

  Future<Map<AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>>
      _load() async {
    final values = await _service.list();
    final result =
        <AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>{
      for (final scope in AiPersonalDataPermissionScope.values)
        scope: AiPersonalDataPermissionPolicy.ask,
    };
    for (final item in values) {
      result[item.scope] = item.policy;
    }
    return result;
  }

  Future<void> _update(
    Map<AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>
        permissions,
    AiPersonalDataPermissionScope scope,
    AiPersonalDataPermissionPolicy policy,
  ) async {
    if (_savingScope != null || permissions[scope] == policy) return;
    final accountUserId = _accountUserId;
    setState(() => _savingScope = scope);
    try {
      final updated = await _service.update(scope: scope, policy: policy);
      if (!mounted || accountUserId != _accountUserId) return;
      setState(() {
        permissions[updated.scope] = updated.policy;
      });
    } on AiPersonalDataPermissionException catch (error) {
      if (mounted) {
        AppFeedback.error(error.message, context: context);
      }
    } finally {
      if (mounted && accountUserId == _accountUserId) {
        setState(() => _savingScope = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('校园 Agent 数据权限')),
      body: FutureBuilder<
          Map<AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>>(
        key: ValueKey('permission-future-$_accountUserId'),
        future: _permissions,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: FilledButton.icon(
                onPressed: () => setState(() => _permissions = _load()),
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载'),
              ),
            );
          }
          final permissions = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              const Text(
                '这些设置仅适用于服务器上的校园 Agent。个人 AI 仍然只读取当前手机的本地加密缓存。',
                style: TextStyle(height: 1.5),
              ),
              const SizedBox(height: 12),
              ...AiPersonalDataPermissionScope.values.map(
                (scope) => _permissionTile(permissions, scope),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _permissionTile(
    Map<AiPersonalDataPermissionScope, AiPersonalDataPermissionPolicy>
        permissions,
    AiPersonalDataPermissionScope scope,
  ) {
    final policy = permissions[scope] ?? AiPersonalDataPermissionPolicy.ask;
    final saving = _savingScope == scope;
    if (scope == AiPersonalDataPermissionScope.remoteEduRefresh) {
      return Semantics(
        enabled: false,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(_scopeIcon(scope)),
          title: Text(_scopeTitle(scope)),
          subtitle: Text(_scopeDescription(scope)),
          trailing: const Chip(label: Text('暂未开放')),
        ),
      );
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(_scopeIcon(scope)),
      title: Text(_scopeTitle(scope)),
      subtitle: Text(_scopeDescription(scope)),
      trailing: saving
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : PopupMenuButton<AiPersonalDataPermissionPolicy>(
              tooltip: '修改${_scopeTitle(scope)}权限',
              initialValue: policy,
              onSelected: (next) => _update(permissions, scope, next),
              itemBuilder: (context) => AiPersonalDataPermissionPolicy.values
                  .map(
                    (item) => PopupMenuItem(
                      value: item,
                      child: Text(_policyLabel(item)),
                    ),
                  )
                  .toList(growable: false),
              child: Chip(label: Text(_policyLabel(policy))),
            ),
    );
  }

  String _scopeTitle(AiPersonalDataPermissionScope scope) => switch (scope) {
        AiPersonalDataPermissionScope.personalDataAccess => '个人数据总开关',
        AiPersonalDataPermissionScope.deviceCacheAccess => '读取手机本地缓存',
        AiPersonalDataPermissionScope.remoteEduRefresh => 'AI 主动刷新教务',
        AiPersonalDataPermissionScope.erkeSnapshotUpload => '上传二课结构化摘要',
        AiPersonalDataPermissionScope.academicCloudStorage => '使用服务端学业快照',
        AiPersonalDataPermissionScope.externalModelAnalysis => '外部模型辅助分析',
      };

  String _scopeDescription(AiPersonalDataPermissionScope scope) =>
      switch (scope) {
        AiPersonalDataPermissionScope.personalDataAccess =>
          '关闭后校园 Agent 不再使用任何个人数据。',
        AiPersonalDataPermissionScope.deviceCacheAccess =>
          '仅允许手机返回本次问题所需的最小化只读结果。',
        AiPersonalDataPermissionScope.remoteEduRefresh =>
          'AI 主动刷新教务暂未开放。既有教务刷新完成后，AI 可继续处理等待中的任务。',
        AiPersonalDataPermissionScope.erkeSnapshotUpload =>
          '仅保存汇总、分类缺口和活动摘要，不包含密码或 Cookie。',
        AiPersonalDataPermissionScope.academicCloudStorage =>
          '允许校园 Agent 使用已保存的服务端成绩和课表快照。',
        AiPersonalDataPermissionScope.externalModelAnalysis =>
          '允许将经过最小化和去身份处理的专业年级、课程成绩、学分、课表时间及二课摘要发送给统一 AI 模型服务。不会发送姓名、学号、密码、Cookie 或 Token。',
      };

  IconData _scopeIcon(AiPersonalDataPermissionScope scope) => switch (scope) {
        AiPersonalDataPermissionScope.personalDataAccess =>
          Icons.admin_panel_settings_outlined,
        AiPersonalDataPermissionScope.deviceCacheAccess => Icons.phone_android,
        AiPersonalDataPermissionScope.remoteEduRefresh => Icons.sync,
        AiPersonalDataPermissionScope.erkeSnapshotUpload =>
          Icons.cloud_upload_outlined,
        AiPersonalDataPermissionScope.academicCloudStorage =>
          Icons.cloud_done_outlined,
        AiPersonalDataPermissionScope.externalModelAnalysis =>
          Icons.hub_outlined,
      };

  String _policyLabel(AiPersonalDataPermissionPolicy policy) =>
      switch (policy) {
        AiPersonalDataPermissionPolicy.ask => '每次询问',
        AiPersonalDataPermissionPolicy.always => '始终允许',
        AiPersonalDataPermissionPolicy.never => '永不允许',
      };
}
