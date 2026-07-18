import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/auth_provider.dart';
import '../widgets/required_legal_consent_dialog.dart';
import '../services/push_settings_service.dart';
import 'legal_documents_screen.dart';

class PrivacyCenterScreen extends StatefulWidget {
  final bool restricted;

  const PrivacyCenterScreen({super.key, this.restricted = false});

  @override
  State<PrivacyCenterScreen> createState() => _PrivacyCenterScreenState();
}

class _PrivacyCenterScreenState extends State<PrivacyCenterScreen> {
  List<Map<String, dynamic>> _requests = const [];
  bool _loadingRequests = true;
  bool _loadingData = false;
  bool _exporting = false;
  bool _revoking = false;
  bool _pushEnabled = false;
  bool _pushLoading = true;

  @override
  void initState() {
    super.initState();
    _loadRequests();
    PushSettingsService.isEnabled().then((enabled) {
      if (mounted)
        setState(() {
          _pushEnabled = enabled;
          _pushLoading = false;
        });
    });
  }

  Future<void> _loadRequests() async {
    try {
      final response =
          await context.read<AuthProvider>().dio.get('/user/privacy/requests');
      final items = response.data is Map ? response.data['items'] : null;
      if (mounted) {
        setState(() {
          _requests = items is List
              ? items
                  .whereType<Map>()
                  .map((item) => Map<String, dynamic>.from(item))
                  .toList()
              : const [];
          _loadingRequests = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingRequests = false);
    }
  }

  Future<void> _showRequestDialog() async {
    var requestType = 'correction';
    final detailController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) => AlertDialog(
          title: const Text('申请更正或删除'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: requestType,
              items: const [
                DropdownMenuItem(value: 'correction', child: Text('更正个人信息')),
                DropdownMenuItem(value: 'deletion', child: Text('删除个人信息或内容')),
              ],
              onChanged: (value) =>
                  setDialogState(() => requestType = value ?? 'correction'),
            ),
            TextField(
                controller: detailController, maxLength: 500, maxLines: 3),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('提交')),
          ],
        ),
      ),
    );
    if (submitted != true) {
      detailController.dispose();
      return;
    }
    try {
      await context
          .read<AuthProvider>()
          .dio
          .post('/user/privacy/requests', data: {
        'request_type': requestType,
        'detail': detailController.text.trim(),
      });
      _showMessage('请求已提交');
      await _loadRequests();
    } on DioException catch (error) {
      _showMessage(_errorMessage(error));
    } finally {
      detailController.dispose();
    }
  }

  Future<void> _showRequestHistory() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('个人信息请求记录',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          if (_requests.isEmpty)
            const Text('暂无个人信息请求记录')
          else
            ..._requests.map((request) => ListTile(
                  title: Text(request['request_type']?.toString() ?? '请求'),
                  subtitle: Text(
                      request['result']?.toString().isNotEmpty == true
                          ? request['result'].toString()
                          : request['status']?.toString() ?? 'pending'),
                )),
        ],
      ),
    );
  }

  Future<void> _setPushEnabled(bool enabled) async {
    if (_pushLoading) return;
    setState(() => _pushLoading = true);
    final auth = context.read<AuthProvider>();
    if (enabled) {
      await PushSettingsService.enable();
      var permissionGranted = false;
      try {
        permissionGranted =
            await PushSettingsService.requestSystemNotificationPermission();
      } catch (error) {
        debugPrint('请求推送通知权限失败: $error');
      }
      if (mounted) {
        setState(() {
          _pushEnabled = true;
          _pushLoading = false;
        });
        _showMessage(permissionGranted ? '已开启推送通知' : '已记录推送选择，但通知权限未开启');
      }
      return;
    }
    final result = await PushSettingsService.disable(auth);
    if (!mounted) return;
    setState(() => _pushLoading = false);
    if (!result.success) {
      _showMessage(result.errorMessage ?? '关闭远程推送失败');
      return;
    }
    setState(() => _pushEnabled = false);
    _showMessage('已关闭远程推送，课程和考试提醒不受影响');
  }

  Future<void> _showPersonalData() async {
    if (_loadingData) return;
    setState(() => _loadingData = true);
    try {
      final response =
          await context.read<AuthProvider>().dio.get('/user/privacy/data');
      if (response.data is! Map) throw const FormatException('个人信息响应无效');
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => _PersonalDataScreen(
            data: Map<String, dynamic>.from(response.data as Map),
          ),
        ),
      );
    } on DioException catch (error) {
      _showMessage(_errorMessage(error));
    } catch (_) {
      _showMessage('读取个人信息失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  Future<void> _exportData() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final response =
          await context.read<AuthProvider>().dio.get('/user/privacy/export');
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/shenliyuan-personal-data.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(response.data),
      );
      await Share.shareXFiles([XFile(file.path)], text: '我的个人信息导出文件');
    } on DioException catch (error) {
      _showMessage(_errorMessage(error));
    } catch (_) {
      _showMessage('导出失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _withdrawConsent() async {
    if (_revoking) return;
    var password = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('撤销全部同意'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('撤销后，社区、教务、消息和其他依赖授权的功能将立即停止使用，已保存的教务凭证和推送标识会被清除。'),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('withdraw-consent-password'),
              obscureText: true,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: '输入 APP 密码确认'),
              onChanged: (value) => password = value,
              onSubmitted: (value) {
                if (value.isNotEmpty) Navigator.pop(dialogContext, true);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-withdraw-consent'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, password.isNotEmpty),
            child: const Text('确认撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true || password.isEmpty || !mounted) return;

    setState(() => _revoking = true);
    final result =
        await context.read<AuthProvider>().withdrawLegalConsents(password);
    if (!mounted) return;
    setState(() => _revoking = false);
    if (!result.success) {
      _showMessage(result.errorMessage ?? '撤销同意失败');
      return;
    }
    await PushSettingsService.clearLocal();
    _showMessage('已撤销全部同意，相关功能已停止使用');
  }

  Future<void> _renewConsent() async {
    final auth = context.read<AuthProvider>();
    await showRequiredLegalConsentDialog(
      context,
      requiresEduDataConsent: auth.user?.eduBound ?? false,
    );
  }

  Future<void> _showCancelAccountDialog() async {
    final passwordController = TextEditingController();
    final auth = context.read<AuthProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('注销账号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('注销不可恢复。账号身份资料、教务凭证和推送标识将被清除或匿名化；必要的内容关联与审计记录会按适用法律保留。'),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: '输入 APP 密码确认'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认注销'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      passwordController.dispose();
      return;
    }
    final result = await auth.deleteAccount(passwordController.text);
    passwordController.dispose();
    if (!mounted) return;
    if (!result.success) {
      _showMessage(result.errorMessage ?? '账号注销失败');
      return;
    }
    await PushSettingsService.clearLocal();
    _showMessage('账号已注销');
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  String _errorMessage(DioException error) {
    final body = error.response?.data;
    if (body is Map && body['error'] != null) return body['error'].toString();
    return '操作失败，请稍后重试';
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final restricted =
        widget.restricted || !(auth.user?.legalConsentsActive ?? true);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.restricted,
        title: const Text('隐私与数据权利'),
        actions: [
          if (restricted)
            IconButton(
              tooltip: '退出登录',
              onPressed: auth.logout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          if (restricted) ...[
            _RestrictedNotice(),
            const SizedBox(height: 20),
          ],
          const _SectionTitle('协议与说明'),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.policy_outlined),
              title: const Text('查看协议、隐私政策与第三方服务说明'),
              subtitle: const Text('包含教务数据专项授权和投诉举报规则'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => LegalDocumentsScreen.open(context),
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('你的数据'),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('access-personal-data'),
                  leading: const Icon(Icons.person_search_outlined),
                  title: const Text('查阅个人信息'),
                  subtitle: const Text('直接查看账户资料、教务绑定和授权记录'),
                  trailing: _loadingData
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _loadingData ? null : _showPersonalData,
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  key: const ValueKey('export-personal-data'),
                  leading: const Icon(Icons.ios_share_outlined),
                  title: const Text('导出个人数据'),
                  subtitle: const Text('生成可分享 JSON，不含认证凭证'),
                  trailing: _exporting
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _exporting ? null : _exportData,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('数据权利请求'),
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              ListTile(
                key: const ValueKey('create-privacy-request'),
                leading: const Icon(Icons.edit_note_outlined),
                title: const Text('申请更正或删除'),
                subtitle: const Text('更正资料，或申请删除特定数据、内容'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showRequestDialog,
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                key: const ValueKey('privacy-request-history'),
                leading: const Icon(Icons.history_outlined),
                title: const Text('查看处理记录'),
                subtitle: Text(_loadingRequests
                    ? '正在读取请求状态'
                    : '共 ${_requests.length} 条记录'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showRequestHistory,
              ),
            ]),
          ),
          const SizedBox(height: 20),
          if (restricted) ...[
            const _SectionTitle('授权管理'),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                key: const ValueKey('renew-legal-consents'),
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('重新授权'),
                subtitle: const Text('重新确认最新协议后恢复正常使用'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _renewConsent,
              ),
            ),
            const SizedBox(height: 20),
          ] else ...[
            const _SectionTitle('授权管理'),
            const SizedBox(height: 8),
            const Card(
              child: ListTile(
                leading: Icon(Icons.tune_outlined),
                title: Text('按功能管理授权'),
                subtitle: Text('教务绑定、远程推送和本地提醒分别关闭或撤回'),
              ),
            ),
            const SizedBox(height: 20),
          ],
          const _SectionTitle('消息与通知'),
          const SizedBox(height: 8),
          Card(
            child: SwitchListTile(
              key: const ValueKey('push-data-processing'),
              secondary: const Icon(Icons.notifications_active_outlined),
              title: const Text('接收远程消息推送'),
              subtitle: Text(widget.restricted
                  ? '账号受限时仅可关闭推送并清理设备标识'
                  : '默认关闭。开启后会向极光提供设备推送标识'),
              value: _pushEnabled,
              onChanged: _pushLoading || (widget.restricted && !_pushEnabled)
                  ? null
                  : _setPushEnabled,
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('账号管理'),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              key: const ValueKey('cancel-account'),
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('注销账号'),
              subtitle: const Text('清除或匿名化账号身份资料，此操作不可恢复'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showCancelAccountDialog,
            ),
          ),
        ],
      ),
    );
  }
}

class _RestrictedNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.block_outlined, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text('授权已撤销，社区、教务、消息等功能已停止使用。'),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _PersonalDataScreen extends StatefulWidget {
  final Map<String, dynamic> data;

  const _PersonalDataScreen({required this.data});

  @override
  State<_PersonalDataScreen> createState() => _PersonalDataScreenState();
}

class _PersonalDataScreenState extends State<_PersonalDataScreen> {
  bool _saving = false;

  static const _accountLabels = <String, String>{
    'id': '用户 ID',
    'student_id': '登录账号',
    'nickname': '昵称',
    'gender': '性别',
    'avatar_set': '头像',
    'background_set': '背景图',
    'qq': 'QQ',
    'created_at': '注册时间',
    'edu_bound': '教务绑定',
    'edu_student_id': '教务学号',
    'edu_grade': '年级',
    'edu_college': '学院',
    'edu_major': '专业',
    'notification_on': '消息推送',
  };

  static const _documentLabels = <String, String>{
    'user_agreement': '用户协议',
    'privacy_policy': '隐私政策',
    'community_rules': '社区规则',
    'minor_protection': '未成年人保护规则',
    'content_complaint_rules': '投诉举报规则',
    'sdk_disclosure': '第三方服务说明',
    'edu_data_consent': '教务数据专项授权',
  };

  Future<void> _saveCopy() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/shenliyuan-personal-data.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(widget.data),
      );
      await Share.shareXFiles([XFile(file.path)], text: '我的个人信息副本');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存副本失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.data['account'] is Map
        ? Map<String, dynamic>.from(widget.data['account'] as Map)
        : const <String, dynamic>{};
    final consents = widget.data['legal_consents'] is List
        ? (widget.data['legal_consents'] as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
    final active = widget.data['legal_consents_active'] == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的个人信息'),
        actions: [
          IconButton(
            tooltip: '保存副本',
            onPressed: _saving ? null : _saveCopy,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Row(
            children: [
              const Expanded(child: _SectionTitle('账户资料')),
              Chip(label: Text(active ? '授权有效' : '授权未生效')),
            ],
          ),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: _accountLabels.entries
                  .where((entry) => account.containsKey(entry.key))
                  .map(
                    (entry) => _DataRow(
                      label: entry.value,
                      value: _formatValue(entry.key, account[entry.key]),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
          const SizedBox(height: 20),
          const _SectionTitle('授权记录'),
          const SizedBox(height: 8),
          if (consents.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('暂无可显示的授权记录'),
              ),
            )
          else
            Card(
              child: Column(
                children: consents.map((consent) {
                  final document = consent['document']?.toString() ?? '';
                  final revoked = consent['revoked_at'] != null;
                  return ListTile(
                    dense: true,
                    title: Text(_documentLabels[document] ?? document),
                    subtitle: Text(
                      '版本 ${consent['version'] ?? '-'} · ${revoked ? '已撤销' : '已同意'}',
                    ),
                    trailing: Icon(
                      revoked
                          ? Icons.remove_circle_outline
                          : Icons.check_circle_outline,
                      size: 20,
                      color: revoked
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                  );
                }).toList(growable: false),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            widget.data['scope']?.toString() ?? '',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  String _formatValue(String key, dynamic value) {
    if (value == null || value.toString().trim().isEmpty) return '未填写';
    if (key == 'avatar_set' || key == 'background_set') {
      return value == true ? '已设置' : '未设置';
    }
    if (value is bool) return value ? '是' : '否';
    return value.toString();
  }
}

class _DataRow extends StatelessWidget {
  final String label;
  final String value;

  const _DataRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
