import 'academic_data_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/domain/academic_repository.dart';
import '../providers/auth_provider.dart';
import '../widgets/campus/campus_theme.dart';
import '../widgets/settings/settings_page_scaffold.dart';
import '../widgets/settings/settings_section.dart';
import '../widgets/settings/settings_status_badge.dart';
import '../widgets/settings/settings_tile.dart';

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

  bool get _emailBound =>
      _security?['email_bound'] == true ||
      context.read<AuthProvider>().user?.emailBound == true;

  String get _emailLabel => _security?['email']?.toString().isNotEmpty == true
      ? _security!['email'].toString()
      : context.read<AuthProvider>().user?.emailMasked ?? '';

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
              style: FilledButton.styleFrom(
                backgroundColor: CampusTheme.red,
              ),
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SettingsPageScaffold(
        title: '账号与安全',
        children: [
          Center(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(),
            ),
          ),
        ],
      );
    }

    final localAcademic = context.watch<AcademicSessionController>();
    final usesLocalAcademic =
        localAcademic.sourceKind == AcademicSourceKind.local;
    final supportsGrades = localAcademic.capabilities.supportsGrades;
    final identity = localAcademic.identity;
    final user = context.watch<AuthProvider>().user;
    final loginAccount =
        _security?['login_account']?.toString() ?? user?.loginAccount ?? '';
    final accountLabel =
        loginAccount.isNotEmpty ? loginAccount : 'App ID ${user?.id ?? ''}';
    final loginMethods =
        (_security?['login_methods'] as List? ?? user?.loginMethods ?? const [])
            .map((method) => method == 'student_id' ? '原学号（兼容）' : '邮箱')
            .join('、');

    return SettingsPageScaffold(
      title: '账号与安全',
      onRefresh: _reload,
      children: [
        // 顶部状态卡
        SettingsSection(
          title: '状态卡',
          children: [
            SettingsTile(
              icon: Icons.verified_user_outlined,
              title: '当前教务账号',
              subtitle: identity == null
                  ? '尚未配置教务账号'
                  : '${identity.providerId.displayName} · ${identity.studentId}',
              trailing: SettingsStatusBadge(
                label: identity == null ? '未配置' : '已配置',
                type: identity != null
                    ? SettingsStatusBadgeType.success
                    : SettingsStatusBadgeType.neutral,
              ),
              showChevron: false,
            ),
            SettingsTile(
              icon: Icons.mark_email_read_outlined,
              title: '安全邮箱状态',
              subtitle: _emailBound ? _emailLabel : '请绑定邮箱，用于 App 登录与找回密码',
              trailing: SettingsStatusBadge(
                label: _emailBound ? '已绑定' : '未绑定',
                type: _emailBound
                    ? SettingsStatusBadgeType.success
                    : SettingsStatusBadgeType.neutral,
              ),
              showChevron: false,
            ),
            SettingsTile(
              icon: Icons.school_outlined,
              title: '教务系统状态',
              subtitle: usesLocalAcademic
                  ? '本机直连教务，会话材料仅保存在设备安全存储或内存中'
                  : '新身份路径只保存确认状态，旧兼容部署可能保存必要凭据',
              trailing: SettingsStatusBadge(
                label: localAcademic.isAuthenticated ? '已连接' : '未连接',
                type: localAcademic.isAuthenticated
                    ? SettingsStatusBadgeType.success
                    : SettingsStatusBadgeType.neutral,
              ),
              showChevron: false,
            ),
          ],
        ),

        // 账号身份
        SettingsSection(
          title: '账号身份',
          children: [
            SettingsTile(
              icon: Icons.badge_outlined,
              title: 'App 登录账号：$accountLabel',
              subtitle: '更换或解绑教务不会改变 App 登录账号',
              showChevron: false,
            ),
            SettingsTile(
              icon: Icons.email_outlined,
              title: _emailBound ? '邮箱：$_emailLabel' : '邮箱未绑定',
              subtitle: _emailBound ? '请使用邮箱和 App 密码登录' : '请完成邮箱验证，之后使用邮箱登录',
              onTap: _showEmailEditor,
            ),
            if (_emailBound)
              SettingsTile(
                icon: Icons.link_off_outlined,
                title: '解除邮箱',
                subtitle: '解除前需保留可用的其他登录方式',
                onTap: _removeEmail,
                danger: true,
              ),
          ],
        ),

        // 登录与找回
        SettingsSection(
          title: '登录与找回',
          children: [
            SettingsTile(
              icon: Icons.key_outlined,
              title: 'APP 登录方式',
              subtitle: loginMethods.isNotEmpty ? loginMethods : '学号 / 邮箱',
              showChevron: false,
            ),
            SettingsTile(
              icon: Icons.password_outlined,
              title: '修改 APP 密码',
              subtitle: '更改沈理校园账号的登录密码',
              onTap: _showChangePasswordDialog,
            ),
          ],
        ),

        // 教务连接
        SettingsSection(
          title: '教务连接',
          children: [
            SettingsTile(
              icon: Icons.school_outlined,
              title: '教务身份与本机连接',
              subtitle: '管理本科、研究生教务账号和本机连接',
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const AcademicDataSettingsScreen()));
                if (mounted) await _reload();
              },
            ),
            SettingsTile(
              icon: Icons.hub_outlined,
              title: '本机教务资料缓存',
              subtitle: supportsGrades
                  ? '课表、成绩按 App 账号隔离并加密缓存，用于离线查看'
                  : '研究生课表按 App 账号和教务身份隔离并加密缓存，用于离线查看',
              showChevron: false,
            ),
          ],
        ),
      ],
    );
  }
}
