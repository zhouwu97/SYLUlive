import 'dart:async';

import 'package:shenliyuan/widgets/app_dialog.dart';
import 'academic_data_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/domain/academic_repository.dart';
import '../providers/auth_provider.dart';
import '../services/publish_session_scope.dart';
import '../widgets/security_session_guard.dart';
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
  bool _editing = false;
  String? _error;
  int _generation = 0;
  PublishSessionScope? _session;
  int? _observedEpoch;
  int? _observedUserId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    if (_observedEpoch == auth.accountSessionEpoch &&
        _observedUserId == auth.user?.id) {
      return;
    }
    _observedEpoch = auth.accountSessionEpoch;
    _observedUserId = auth.user?.id;
    _session = auth.isLoggedIn && auth.user != null
        ? PublishSessionScope(
            accountId: auth.user!.id,
            accountSessionEpoch: auth.accountSessionEpoch)
        : null;
    _generation++;
    _security = null;
    _editing = false;
    _loading = _session != null;
    _error = _session == null ? '请先登录后查看账号与安全' : null;
    final session = _session;
    if (session != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_owns(session)) _reload();
      });
    }
  }

  bool _owns(PublishSessionScope session) =>
      mounted &&
      SecuritySessionGuard.owns(context.read<AuthProvider>(), session);

  Future<void> _reload() async {
    final session = _session;
    if (session == null || !_owns(session)) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _security = null;
    });
    Map<String, dynamic>? data;
    try {
      data = await context.read<AuthProvider>().getAccountSecurity();
    } catch (_) {/* 显式错误态可重试。 */}
    if (!_owns(session) || generation != _generation) return;
    setState(() {
      _security = data;
      _loading = false;
      _error = data == null ? '账号安全信息加载失败，请重试' : null;
    });
  }

  bool get _emailBound => _security?['email_bound'] as bool? ?? false;
  String get _emailLabel => _security?['email']?.toString().isNotEmpty == true
      ? _security!['email'].toString()
      : context.read<AuthProvider>().user?.emailMasked ?? '';

  Future<void> _showEmailEditor() async {
    final session = _session;
    if (_editing || session == null || !_owns(session)) return;
    _editing = true;
    final auth = context.read<AuthProvider>();
    var email = _security?['email']?.toString() ?? '';
    var code = '';
    var password = '';
    var sending = false;
    var submitting = false;
    final bound = _emailBound;
    final formKey = GlobalKey<FormState>();
    final emailKey = GlobalKey<FormFieldState<String>>();
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SecuritySessionGuard(
          auth: auth,
          session: session,
          child: StatefulBuilder(
              builder: (dialogContext, update) => PopScope(
                    canPop: !submitting,
                    child: AppAlertDialog(
                      title: Text(bound ? '修改邮箱' : '绑定邮箱'),
                      content: SingleChildScrollView(
                          child: Form(
                              key: formKey,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextFormField(
                                      key: emailKey,
                                      initialValue: email,
                                      onChanged: (value) => email = value,
                                      enabled: !submitting && !sending,
                                      keyboardType: TextInputType.emailAddress,
                                      autocorrect: false,
                                      decoration: const InputDecoration(
                                          labelText: '邮箱'),
                                      validator: (value) =>
                                          RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                                  .hasMatch(value?.trim() ?? '')
                                              ? null
                                              : '请输入有效邮箱'),
                                  TextFormField(
                                      onChanged: (value) => code = value,
                                      enabled: !submitting,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                          labelText: '验证码'),
                                      validator: (value) => RegExp(r'^\d{6}$')
                                              .hasMatch(value?.trim() ?? '')
                                          ? null
                                          : '请输入 6 位数字验证码'),
                                  Align(
                                      alignment: Alignment.centerRight,
                                      child: _EmailCodeButton(
                                        disabled: submitting,
                                        onBusyChanged: (value) {
                                          if (dialogContext.mounted) {
                                            update(() => sending = value);
                                          }
                                        },
                                        send: () async {
                                          if (!_owns(session)) {
                                            return AuthResult.failure(
                                                '登录状态已变化');
                                          }
                                          if (emailKey.currentState
                                                  ?.validate() !=
                                              true) {
                                            return AuthResult.failure(
                                                '请输入有效邮箱');
                                          }
                                          return auth.requestUserEmailCode(
                                              email.trim());
                                        },
                                      )),
                                  TextFormField(
                                      onChanged: (value) => password = value,
                                      enabled: !submitting,
                                      obscureText: true,
                                      enableSuggestions: false,
                                      autocorrect: false,
                                      decoration: const InputDecoration(
                                          labelText: '当前 APP 密码'),
                                      validator: (value) =>
                                          value == null || value.isEmpty
                                              ? '请输入当前密码'
                                              : null),
                                ],
                              ))),
                      actions: [
                        TextButton(
                            onPressed: submitting
                                ? null
                                : () => Navigator.pop(dialogContext),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: submitting || sending
                                ? null
                                : () async {
                                    if (submitting ||
                                        sending ||
                                        !_owns(session) ||
                                        !formKey.currentState!.validate()) {
                                      return;
                                    }
                                    update(() => submitting = true);
                                    final result = await auth.updateUserEmail(
                                        email: email.trim(),
                                        code: code.trim(),
                                        password: password);
                                    if (!dialogContext.mounted ||
                                        !_owns(session)) {
                                      return;
                                    }
                                    if (result.success) {
                                      Navigator.pop(dialogContext);
                                      _message(bound ? '邮箱已修改' : '邮箱已绑定');
                                      await _reload();
                                    } else {
                                      update(() => submitting = false);
                                      _message(result.errorMessage ?? '更新失败');
                                    }
                                  },
                            child: Text(submitting ? '提交中…' : '确认')),
                      ],
                    ),
                  )),
        ),
      );
    } finally {
      if (_owns(session)) _editing = false;
    }
  }

  Future<void> _removeEmail() async {
    final session = _session;
    if (_editing || session == null || !_owns(session)) return;
    _editing = true;
    final auth = context.read<AuthProvider>();
    var password = '';
    var submitting = false;
    final formKey = GlobalKey<FormState>();
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SecuritySessionGuard(
          auth: auth,
          session: session,
          child: StatefulBuilder(
              builder: (dialogContext, update) => PopScope(
                    canPop: !submitting,
                    child: AppAlertDialog(
                      title: const Text('解除邮箱'),
                      content: SingleChildScrollView(
                          child: Form(
                              key: formKey,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                      '解除后将无法使用此邮箱登录或找回密码，请确认仍可使用其他登录方式。'),
                                  TextFormField(
                                      onChanged: (value) => password = value,
                                      obscureText: true,
                                      enabled: !submitting,
                                      enableSuggestions: false,
                                      autocorrect: false,
                                      decoration: const InputDecoration(
                                          labelText: '当前 APP 密码'),
                                      validator: (value) =>
                                          value == null || value.isEmpty
                                              ? '请输入当前密码'
                                              : null),
                                ],
                              ))),
                      actions: [
                        TextButton(
                            onPressed: submitting
                                ? null
                                : () => Navigator.pop(dialogContext),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: submitting
                                ? null
                                : () async {
                                    if (submitting ||
                                        !_owns(session) ||
                                        !formKey.currentState!.validate()) {
                                      return;
                                    }
                                    update(() => submitting = true);
                                    final result =
                                        await auth.removeUserEmail(password);
                                    if (!dialogContext.mounted ||
                                        !_owns(session)) {
                                      return;
                                    }
                                    if (result.success) {
                                      Navigator.pop(dialogContext);
                                      _message('邮箱已解除');
                                      await _reload();
                                    } else {
                                      update(() => submitting = false);
                                      _message(result.errorMessage ?? '解除失败');
                                    }
                                  },
                            style: FilledButton.styleFrom(
                                backgroundColor: CampusTheme.red),
                            child: Text(submitting ? '解除中…' : '解除')),
                      ],
                    ),
                  )),
        ),
      );
    } finally {
      if (_owns(session)) _editing = false;
    }
  }

  Future<void> _showChangePasswordDialog() async {
    final session = _session;
    if (_editing || session == null || !_owns(session)) return;
    _editing = true;
    final auth = context.read<AuthProvider>();
    var oldPassword = '';
    var newPassword = '';
    var submitting = false;
    final formKey = GlobalKey<FormState>();
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SecuritySessionGuard(
          auth: auth,
          session: session,
          child: StatefulBuilder(
              builder: (dialogContext, update) => PopScope(
                    canPop: !submitting,
                    child: AppAlertDialog(
                      title: const Text('修改 APP 密码'),
                      content: SingleChildScrollView(
                          child: Form(
                              key: formKey,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextFormField(
                                      onChanged: (value) => oldPassword = value,
                                      obscureText: true,
                                      enabled: !submitting,
                                      enableSuggestions: false,
                                      autocorrect: false,
                                      decoration: const InputDecoration(
                                          labelText: '当前 APP 密码'),
                                      validator: (value) =>
                                          value == null || value.isEmpty
                                              ? '请输入当前密码'
                                              : null),
                                  TextFormField(
                                      onChanged: (value) => newPassword = value,
                                      obscureText: true,
                                      enabled: !submitting,
                                      enableSuggestions: false,
                                      autocorrect: false,
                                      decoration: const InputDecoration(
                                          labelText: '新 APP 密码'),
                                      validator: (value) => value == null ||
                                              value.runes.length < 8 ||
                                              value.runes.length > 32
                                          ? '请输入 8–32 位密码'
                                          : null),
                                ],
                              ))),
                      actions: [
                        TextButton(
                            onPressed: submitting
                                ? null
                                : () => Navigator.pop(dialogContext),
                            child: const Text('取消')),
                        FilledButton(
                            onPressed: submitting
                                ? null
                                : () async {
                                    if (submitting ||
                                        !_owns(session) ||
                                        !formKey.currentState!.validate()) {
                                      return;
                                    }
                                    update(() => submitting = true);
                                    final result = await auth.changePassword(
                                        oldPassword, newPassword);
                                    if (!dialogContext.mounted ||
                                        !_owns(session)) {
                                      return;
                                    }
                                    if (result.success) {
                                      Navigator.pop(dialogContext);
                                      _message('密码已修改');
                                    } else {
                                      update(() => submitting = false);
                                      _message(result.errorMessage ?? '修改失败');
                                    }
                                  },
                            child: Text(submitting ? '提交中…' : '确认')),
                      ],
                    ),
                  )),
        ),
      );
    } finally {
      if (_owns(session)) _editing = false;
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return SettingsPageScaffold(
          title: '账号与安全',
          onRefresh: _reload,
          children: [
            Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  Text(_error!, textAlign: TextAlign.center),
                  if (_session != null)
                    TextButton(onPressed: _reload, child: const Text('重试')),
                ]))
          ]);
    }
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
            if (_emailBound &&
                (_security?['login_methods'] as List? ?? const [])
                    .contains('student_id'))
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

class _EmailCodeButton extends StatefulWidget {
  const _EmailCodeButton(
      {required this.send,
      required this.onBusyChanged,
      required this.disabled});
  final Future<AuthResult> Function() send;
  final ValueChanged<bool> onBusyChanged;
  final bool disabled;
  @override
  State<_EmailCodeButton> createState() => _EmailCodeButtonState();
}

class _EmailCodeButtonState extends State<_EmailCodeButton> {
  bool _sending = false;
  int _cooldown = 0;
  Timer? _timer;
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending || _cooldown > 0 || widget.disabled) return;
    setState(() => _sending = true);
    widget.onBusyChanged(true);
    AuthResult result;
    try {
      result = await widget.send();
    } catch (_) {
      result = AuthResult.failure('发送失败，请稍后重试');
    }
    if (!mounted) return;
    widget.onBusyChanged(false);
    setState(() {
      _sending = false;
      _cooldown = (result.success
              ? result.retryAfterSeconds ?? 60
              : result.retryAfterSeconds ?? 0)
          .clamp(0, 86400);
    });
    if (_cooldown > 0) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _cooldown--);
        if (_cooldown <= 0) timer.cancel();
      });
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(result.success ? '验证码已发送' : result.errorMessage ?? '发送失败')));
  }

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: _sending || _cooldown > 0 || widget.disabled ? null : _send,
        child: Text(_sending
            ? '发送中…'
            : _cooldown > 0
                ? '$_cooldown 秒后重试'
                : '发送验证码'),
      );
}
