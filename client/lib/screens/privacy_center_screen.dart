import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../providers/auth_provider.dart';
import 'legal_documents_screen.dart';

class PrivacyCenterScreen extends StatefulWidget {
  final bool restricted;

  const PrivacyCenterScreen({super.key, this.restricted = false});

  @override
  State<PrivacyCenterScreen> createState() => _PrivacyCenterScreenState();
}

class _PrivacyCenterScreenState extends State<PrivacyCenterScreen> {
  bool _loadingData = false;
  bool _revoking = false;

  Future<void> _showPersonalData() async {
    if (_loadingData) return;
    setState(() => _loadingData = true);
    try {
      final response =
          await context.read<AuthProvider>().dio.get('/user/privacy/data');
      if (response.data is! Map) throw const FormatException('个人信息响应无效');
      final data = Map<String, dynamic>.from(response.data as Map);
      if (!mounted) return;
      setState(() => _loadingData = false);
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => _PersonalDataScreen(data: data)),
      );
    } on DioException catch (error) {
      _showMessage(_errorMessage(error));
    } catch (_) {
      _showMessage('读取个人信息失败，请稍后重试');
    } finally {
      if (mounted && _loadingData) setState(() => _loadingData = false);
    }
  }

  Future<void> _withdrawConsent() async {
    if (_revoking) return;
    var enteredPassword = '';
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('撤销全部同意'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '撤销后，社区、教务、消息和其他依赖授权的功能将立即停止使用，已保存的教务凭证和推送标识会被清除。',
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('withdraw-consent-password'),
              obscureText: true,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '输入 APP 密码确认',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              onChanged: (value) => enteredPassword = value,
              onSubmitted: (value) {
                if (value.isNotEmpty) Navigator.pop(dialogContext, value);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-withdraw-consent'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              if (enteredPassword.isNotEmpty) {
                Navigator.pop(dialogContext, enteredPassword);
              }
            },
            child: const Text('确认撤销'),
          ),
        ],
      ),
    );
    if (password == null || password.isEmpty || !mounted) return;

    setState(() => _revoking = true);
    final result =
        await context.read<AuthProvider>().withdrawLegalConsents(password);
    if (!mounted) return;
    setState(() => _revoking = false);
    if (!result.success) {
      _showMessage(result.errorMessage ?? '撤销同意失败');
      return;
    }
    _showMessage('已撤销全部同意，相关功能已停止使用');
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _cancelAccount() async {
    var enteredPassword = '';
    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('注销账号'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '注销后无法恢复。账号身份资料、教务凭证和推送标识会被清除或匿名化，必要的内容关联与审计记录会按规定保留。',
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('cancel-account-password'),
              obscureText: true,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '输入 APP 密码确认',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              onChanged: (value) => enteredPassword = value,
              onSubmitted: (value) {
                if (value.isNotEmpty) Navigator.pop(dialogContext, value);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-cancel-account'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              if (enteredPassword.isNotEmpty) {
                Navigator.pop(dialogContext, enteredPassword);
              }
            },
            child: const Text('确认注销'),
          ),
        ],
      ),
    );
    if (password == null || password.isEmpty || !mounted) return;

    final result = await context.read<AuthProvider>().deleteAccount(password);
    if (!mounted) return;
    if (!result.success) {
      _showMessage(result.errorMessage ?? '账号注销失败');
      return;
    }
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
    final consentsActive = auth.user?.legalConsentsActive ?? true;
    final restricted = widget.restricted || !consentsActive;

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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (restricted) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .errorContainer
                    .withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.block_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('授权已撤销，仅保留个人信息查阅、账号注销和退出登录。'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          const _SectionTitle('协议与说明'),
          const SizedBox(height: 6),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.policy_outlined),
              title: const Text('协议、隐私政策与第三方服务说明'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => LegalDocumentsScreen.open(context),
            ),
          ),
          const SizedBox(height: 18),
          const _SectionTitle('你的数据权利'),
          const SizedBox(height: 6),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('access-personal-data'),
                  dense: true,
                  leading: const Icon(Icons.person_search_outlined),
                  title: const Text('查阅个人信息'),
                  subtitle: const Text('直接查看账户资料和授权记录'),
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
                  key: const ValueKey('withdraw-legal-consents'),
                  dense: true,
                  leading: Icon(
                    consentsActive
                        ? Icons.no_accounts_outlined
                        : Icons.check_circle_outline,
                    color: consentsActive
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  title: const Text('撤销同意'),
                  subtitle: Text(
                    consentsActive ? '立即停止全部依赖授权的功能' : '已撤销，依赖授权的功能不可用',
                  ),
                  trailing: _revoking
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  onTap: consentsActive && !_revoking ? _withdrawConsent : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const _SectionTitle('账号管理'),
          const SizedBox(height: 6),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              key: const ValueKey('cancel-account'),
              dense: true,
              leading: Icon(
                Icons.delete_forever_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('注销账号'),
              subtitle: const Text('清除或匿名化账号身份资料，此操作不可恢复'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _cancelAccount,
            ),
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
    'avatar': '头像地址',
    'background': '背景图地址',
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
            .toList()
        : const <Map<String, dynamic>>[];
    final active = widget.data['legal_consents_active'] != false;

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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Row(
            children: [
              const Expanded(child: _SectionTitle('账户资料')),
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text(active ? '授权有效' : '授权已撤销'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: _accountLabels.entries
                  .where((entry) => account.containsKey(entry.key))
                  .map(
                    (entry) => _DataRow(
                      label: entry.value,
                      value: _formatValue(account[entry.key]),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 18),
          const _SectionTitle('授权记录'),
          const SizedBox(height: 6),
          if (consents.isEmpty)
            const Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text('暂无可显示的授权记录'),
              ),
            )
          else
            Card(
              margin: EdgeInsets.zero,
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
                }).toList(),
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

  String _formatValue(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) return '未填写';
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
