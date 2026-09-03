import 'package:flutter/material.dart';

import '../../theme/app_radius.dart';
import '../../theme/app_spacing.dart';

enum DeviceCredentialKind { education, erke, physical }

class DeviceCredentialInput {
  const DeviceCredentialInput({
    required this.password,
    this.secondaryPassword = '',
    this.saveOnDevice = false,
  });

  final String password;
  final String secondaryPassword;
  final bool saveOnDevice;
}

/// 在当前聊天流程内补齐设备刷新所需的凭据。
///
/// 本组件只返回用户输入，不负责持久化；调用方必须在验证成功后再写安全存储。
class DeviceCredentialPromptSheet extends StatefulWidget {
  const DeviceCredentialPromptSheet({
    super.key,
    required this.kind,
    required this.sourceAccountId,
  });

  final DeviceCredentialKind kind;
  final String sourceAccountId;

  static Future<DeviceCredentialInput?> request(
    BuildContext context, {
    required DeviceCredentialKind kind,
    required String sourceAccountId,
  }) {
    return showModalBottomSheet<DeviceCredentialInput>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => DeviceCredentialPromptSheet(
        kind: kind,
        sourceAccountId: sourceAccountId,
      ),
    );
  }

  @override
  State<DeviceCredentialPromptSheet> createState() =>
      _DeviceCredentialPromptSheetState();
}

class _DeviceCredentialPromptSheetState
    extends State<DeviceCredentialPromptSheet> {
  final TextEditingController _primary = TextEditingController();
  final TextEditingController _secondary = TextEditingController();
  bool _saveOnDevice = true;
  bool _obscurePrimary = true;
  bool _obscureSecondary = true;
  String? _error;

  @override
  void dispose() {
    _primary.dispose();
    _secondary.dispose();
    super.dispose();
  }

  bool get _hasSecondary => widget.kind == DeviceCredentialKind.erke;

  String get _title => switch (widget.kind) {
        DeviceCredentialKind.education => '验证教务账号',
        DeviceCredentialKind.erke => '更新二课数据',
        DeviceCredentialKind.physical => '更新体测数据',
      };

  String get _description => switch (widget.kind) {
        DeviceCredentialKind.education =>
          '校园 Agent 需要先恢复教务授权。凭证只用于本机直连教务，不会发送给 SYLUlive 服务器，也不会由本组件持久化。',
        DeviceCredentialKind.erke =>
          '需要在本机登录统一认证和二课系统。验证成功后只向 Agent 返回本次问题所需的二课摘要。',
        DeviceCredentialKind.physical =>
          '需要在本机登录体测系统。验证成功后只向 Agent 返回最近一次体测概览。',
      };

  String get _primaryLabel => switch (widget.kind) {
        DeviceCredentialKind.education => '教务密码',
        DeviceCredentialKind.erke => '统一认证密码',
        DeviceCredentialKind.physical => '体测密码',
      };

  void _submit() {
    final primary = _primary.text;
    final secondary = _secondary.text;
    if (primary.isEmpty || (_hasSecondary && secondary.isEmpty)) {
      setState(() => _error = _hasSecondary ? '请填写两个密码' : '请输入密码');
      return;
    }
    Navigator.of(context).pop(
      DeviceCredentialInput(
        password: primary,
        secondaryPassword: secondary,
        saveOnDevice: widget.kind == DeviceCredentialKind.education
            ? false
            : _saveOnDevice,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 160),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.md,
          AppSpacing.xl,
          AppSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.outlineVariant,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(_title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextFormField(
              controller: _primary,
              autofocus: true,
              obscureText: _obscurePrimary,
              textInputAction:
                  _hasSecondary ? TextInputAction.next : TextInputAction.done,
              onFieldSubmitted: _hasSecondary ? null : (_) => _submit(),
              decoration: InputDecoration(
                labelText: _primaryLabel,
                suffixIcon: IconButton(
                  tooltip: _obscurePrimary ? '显示密码' : '隐藏密码',
                  onPressed: () =>
                      setState(() => _obscurePrimary = !_obscurePrimary),
                  icon: Icon(
                    _obscurePrimary
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            if (_hasSecondary) ...[
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _secondary,
                obscureText: _obscureSecondary,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: '二课查询密码',
                  suffixIcon: IconButton(
                    tooltip: _obscureSecondary ? '显示密码' : '隐藏密码',
                    onPressed: () => setState(
                      () => _obscureSecondary = !_obscureSecondary,
                    ),
                    icon: Icon(
                      _obscureSecondary
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
            ],
            if (widget.kind != DeviceCredentialKind.education) ...[
              const SizedBox(height: AppSpacing.sm),
              CheckboxListTile(
                value: _saveOnDevice,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('安全保存到本机'),
                subtitle: const Text('使用系统安全存储加密保存，可在清理个人数据时删除'),
                onChanged: (value) =>
                    setState(() => _saveOnDevice = value ?? false),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _error!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: colors.error),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('稍后'),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: _submit,
                  child: const Text('验证并继续'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
