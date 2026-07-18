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
  List<Map<String, dynamic>> _requests = const [];
  bool _loading = true;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    setState(() => _loading = true);
    try {
      final response =
          await context.read<AuthProvider>().dio.get('/user/privacy/requests');
      final items = response.data is Map ? response.data['items'] : null;
      if (mounted) {
        setState(() {
          _requests = items is List
              ? items
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList()
              : const [];
        });
      }
    } on DioException catch (error) {
      _showMessage(_errorMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
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
          const JsonEncoder.withIndent('  ').convert(response.data));
      await Share.shareXFiles([XFile(file.path)], text: '我的个人信息导出文件');
    } on DioException catch (error) {
      _showMessage(_errorMessage(error));
    } catch (_) {
      _showMessage('导出失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _showRequestDialog() async {
    final detailController = TextEditingController();
    final dio = context.read<AuthProvider>().dio;
    String requestType = 'access';
    final submitted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('提交个人信息请求'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: requestType,
                decoration: const InputDecoration(labelText: '请求类型'),
                items: const [
                  DropdownMenuItem(value: 'access', child: Text('查阅个人信息')),
                  DropdownMenuItem(value: 'correction', child: Text('更正个人信息')),
                  DropdownMenuItem(value: 'export', child: Text('导出个人信息')),
                  DropdownMenuItem(value: 'deletion', child: Text('删除个人信息或内容')),
                  DropdownMenuItem(
                      value: 'withdraw_consent', child: Text('撤回同意')),
                ],
                onChanged: (value) =>
                    setDialogState(() => requestType = value ?? 'access'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: detailController,
                maxLength: 500,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '说明（可选）',
                  hintText: '请说明需要处理的信息、内容或撤回的授权',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
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
      await dio.post(
        '/user/privacy/requests',
        data: {
          'request_type': requestType,
          'detail': detailController.text.trim()
        },
      );
      _showMessage('请求已提交，可在本页跟踪处理状态');
      await _loadRequests();
    } on DioException catch (error) {
      _showMessage(_errorMessage(error));
    } finally {
      detailController.dispose();
    }
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
              child: const Text('取消')),
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
    return Scaffold(
      appBar: AppBar(title: const Text('隐私与数据权利')),
      body: RefreshIndicator(
        onRefresh: _loadRequests,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            const Text('协议与说明',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
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
            const Text('你的数据权利',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.ios_share_outlined),
                    title: const Text('导出我的数据'),
                    subtitle: const Text('账户资料、授权记录和请求记录，不含认证凭证'),
                    trailing: _exporting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.chevron_right),
                    onTap: _exporting ? null : _exportData,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.edit_note_outlined),
                    title: const Text('提交个人信息请求'),
                    subtitle: const Text('查阅、更正、导出、删除或撤回同意'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _showRequestDialog,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('处理进度',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (_loading)
              const Center(
                  child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator()))
            else if (_requests.isEmpty)
              const Card(
                  child: Padding(
                      padding: EdgeInsets.all(18), child: Text('暂无个人信息请求记录')))
            else
              ..._requests.map(_buildRequestCard),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error),
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('注销账号'),
              onPressed: _showCancelAccountDialog,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestCard(Map<String, dynamic> request) {
    final status = request['status']?.toString() ?? 'pending';
    const labels = {
      'access': '查阅个人信息',
      'correction': '更正个人信息',
      'export': '导出个人信息',
      'deletion': '删除个人信息或内容',
      'withdraw_consent': '撤回同意',
      'pending': '待处理',
      'processing': '处理中',
      'completed': '已完成',
      'rejected': '已拒绝',
    };
    final result = request['result']?.toString().trim() ?? '';
    return Card(
      child: ListTile(
        title: Text(labels[request['request_type']] ??
            request['request_type'].toString()),
        subtitle: Text(result.isEmpty
            ? labels[status] ?? status
            : '${labels[status] ?? status}\n$result'),
        isThreeLine: result.isNotEmpty,
        trailing: Chip(label: Text(labels[status] ?? status)),
      ),
    );
  }
}
