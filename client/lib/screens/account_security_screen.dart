import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';

/// 账号身份、邮箱与教务连接的私有设置页。
class AccountSecurityScreen extends StatefulWidget {
  const AccountSecurityScreen({super.key});

  @override
  State<AccountSecurityScreen> createState() => _AccountSecurityScreenState();
}

class _AccountSecurityScreenState extends State<AccountSecurityScreen> {
  Map<String, dynamic>? _security;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final auth = context.read<AuthProvider>();
    final data = await auth.getAccountSecurity();
    if (mounted) {
      setState(() {
        _security = data;
        _loading = false;
      });
    }
  }

  String get _studentId =>
      _security?['student_id']?.toString() ??
      context.read<AuthProvider>().user?.studentId ??
      '';

  bool get _studentVerified =>
      _security?['student_verified'] == true ||
      context.read<AuthProvider>().user?.studentVerified == true;

  bool get _emailBound =>
      _security?['email_bound'] == true ||
      context.read<AuthProvider>().user?.emailBound == true;

  String get _emailLabel => _security?['email']?.toString().isNotEmpty == true
      ? _security!['email'].toString()
      : context.read<AuthProvider>().user?.emailMasked ?? '';

  String get _sessionState =>
      _security?['edu_session_state']?.toString() ??
      context.read<AuthProvider>().user?.eduSessionState ??
      'unbound';

  bool get _eduAuthorized =>
      _security?['edu_authorized'] == true ||
      context.read<AuthProvider>().user?.eduAuthorized == true;

  Future<void> _showEmailEditor() async {
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final email = TextEditingController(text: _security?['email']?.toString());
    final code = TextEditingController();
    final password = TextEditingController();
    var sending = false;
    var submitting = false;
    final formKey = GlobalKey<FormState>();

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(_emailBound ? '修改邮箱' : '绑定邮箱'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: '邮箱'),
                  validator: (value) =>
                      value == null || !value.contains('@') ? '请输入有效邮箱' : null,
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: code,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '验证码'),
                        validator: (value) =>
                            value?.trim().length != 6 ? '请输入 6 位验证码' : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '发送验证码',
                      onPressed: sending
                          ? null
                          : () async {
                              if (email.text.trim().isEmpty) return;
                              setDialogState(() => sending = true);
                              final result = await auth
                                  .requestUserEmailCode(email.text.trim());
                              if (!dialogContext.mounted) return;
                              setDialogState(() => sending = false);
                              messenger.showSnackBar(
                                SnackBar(
                                    content: Text(result.success
                                        ? '验证码已发送'
                                        : result.errorMessage ?? '发送失败')),
                              );
                            },
                      icon: const Icon(Icons.send_outlined),
                    ),
                  ],
                ),
                TextFormField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '当前 APP 密码'),
                  validator: (value) =>
                      value?.isEmpty == true ? '请输入当前密码' : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting ? null : () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      setDialogState(() => submitting = true);
                      final result = await auth.updateUserEmail(
                        email: email.text.trim(),
                        code: code.text.trim(),
                        password: password.text,
                      );
                      if (!dialogContext.mounted) return;
                      if (result.success) {
                        Navigator.pop(dialogContext);
                        await _reload();
                      } else {
                        setDialogState(() => submitting = false);
                        messenger.showSnackBar(
                          SnackBar(
                              content: Text(result.errorMessage ?? '更新失败')),
                        );
                      }
                    },
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
    email.dispose();
    code.dispose();
    password.dispose();
  }

  Future<void> _removeEmail() async {
    final auth = context.read<AuthProvider>();
    final password = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('解除邮箱'),
        content: TextField(
          controller: password,
          obscureText: true,
          decoration: const InputDecoration(labelText: '当前 APP 密码'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('解除')),
        ],
      ),
    );
    if (confirmed == true) {
      final result = await auth.removeUserEmail(password.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  result.success ? '邮箱已解除' : result.errorMessage ?? '解除失败')),
        );
        if (result.success) await _reload();
      }
    }
    password.dispose();
  }

  Future<void> _showChangePasswordDialog() async {
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final oldPassword = TextEditingController();
    final newPassword = TextEditingController();
    final formKey = GlobalKey<FormState>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改 APP 密码'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: oldPassword,
                obscureText: true,
                decoration: const InputDecoration(labelText: '当前 APP 密码'),
                validator: (value) => value?.isEmpty == true ? '请输入当前密码' : null,
              ),
              TextFormField(
                controller: newPassword,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新 APP 密码'),
                validator: (value) =>
                    value == null || value.length < 8 ? '密码至少 8 位' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              final result = await auth.changePassword(
                oldPassword.text,
                newPassword.text,
              );
              if (!dialogContext.mounted) return;
              if (result.success) {
                Navigator.pop(dialogContext);
              }
              if (mounted) {
                messenger.showSnackBar(
                  SnackBar(
                      content: Text(result.success
                          ? '密码已修改'
                          : result.errorMessage ?? '修改失败')),
                );
              }
            },
            child: const Text('确认'),
          ),
        ],
      ),
    );
    oldPassword.dispose();
    newPassword.dispose();
  }

  Future<void> _runEduAction(
      Future<OperationResult<void>> Function() action) async {
    final result = await action();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text(result.success ? '操作成功' : result.errorMessage ?? '操作失败')),
    );
    if (result.success) await _reload();
  }

  String _sessionLabel(String value) {
    switch (value) {
      case 'active':
        return '在线';
      case 'logged_out':
        return '已退出';
      case 'expired':
        return '已过期';
      case 'revoked':
        return '已撤销';
      default:
        return '未连接';
    }
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final edu = context.read<EduProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('账号与安全')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _section(context, '账号身份', [
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(_studentVerified ? '主账号：$_studentId' : '尚未认证学生'),
                subtitle:
                    Text(_studentVerified ? '学生身份已认证' : '完成教务绑定后，学号将成为主账号'),
              ),
              ListTile(
                leading: const Icon(Icons.email_outlined),
                title: Text(_emailBound ? '邮箱：$_emailLabel' : '邮箱未绑定'),
                trailing: IconButton(
                  tooltip: _emailBound ? '修改邮箱' : '绑定邮箱',
                  onPressed: _showEmailEditor,
                  icon: const Icon(Icons.edit_outlined),
                ),
              ),
              if (_emailBound)
                ListTile(
                  leading: const Icon(Icons.link_off_outlined),
                  title: const Text('解除邮箱'),
                  subtitle: const Text('学生认证账号可解除辅助邮箱'),
                  onTap: _removeEmail,
                ),
            ]),
            _section(context, '登录与找回', [
              ListTile(
                leading: const Icon(Icons.key_outlined),
                title: const Text('APP 密码'),
                subtitle: Text(
                    (_security?['login_methods'] as List? ?? const [])
                        .map((method) => method == 'student_id' ? '学号' : '邮箱')
                        .join('、')),
              ),
              ListTile(
                leading: const Icon(Icons.password_outlined),
                title: const Text('修改 APP 密码'),
                onTap: _showChangePasswordDialog,
              ),
            ]),
            _section(context, '教务连接', [
              ListTile(
                leading: const Icon(Icons.school_outlined),
                title: Text(_eduAuthorized ? '教务授权：已授权' : '教务授权：已撤销'),
                subtitle: Text('教务会话：${_sessionLabel(_sessionState)}'),
              ),
              if (_eduAuthorized && _sessionState != 'active')
                ListTile(
                  leading: const Icon(Icons.login_outlined),
                  title: const Text('重新登录教务'),
                  onTap: () => _runEduAction(edu.resumeSession),
                ),
              if (_eduAuthorized && _sessionState == 'active')
                ListTile(
                  leading: const Icon(Icons.logout_outlined),
                  title: const Text('退出教务登录'),
                  subtitle: const Text('保留授权和学生身份，不会自动恢复'),
                  onTap: () => _runEduAction(edu.logoutSession),
                ),
              if (_eduAuthorized)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('撤销教务授权'),
                  subtitle: const Text('删除教务凭据和会话，保留学号与学生身份'),
                  onTap: () => _runEduAction(edu.revokeAuthorization),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}
