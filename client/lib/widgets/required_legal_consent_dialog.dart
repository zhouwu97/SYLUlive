import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../screens/legal_documents_screen.dart';

Future<void> showRequiredLegalConsentDialog(
  BuildContext context, {
  required bool requiresEduDataConsent,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RequiredLegalConsentDialog(
      requiresEduDataConsent: requiresEduDataConsent,
    ),
  );
}

Future<bool> showRequiredCommunityRulesDialog(BuildContext context) async {
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const RequiredLegalConsentDialog(
          requiresEduDataConsent: false,
          communityRulesOnly: true,
        ),
      ) ??
      false;
}

// RequiredLegalConsentDialog 阻止旧用户在确认最新法律文件前进入业务功能。
class RequiredLegalConsentDialog extends StatefulWidget {
  final bool requiresEduDataConsent;
  final bool communityRulesOnly;

  const RequiredLegalConsentDialog({
    super.key,
    required this.requiresEduDataConsent,
    this.communityRulesOnly = false,
  });

  @override
  State<RequiredLegalConsentDialog> createState() =>
      _RequiredLegalConsentDialogState();
}

class _RequiredLegalConsentDialogState
    extends State<RequiredLegalConsentDialog> {
  bool _generalAccepted = false;
  bool _eduAccepted = false;
  bool _submitting = false;
  String? _error;
  bool _serverRequiresEduConsent = false;

  bool get _requiresEduConsent => !widget.communityRulesOnly &&
      (widget.requiresEduDataConsent || _serverRequiresEduConsent);

  bool get _canConfirm =>
      _generalAccepted &&
      (!_requiresEduConsent || _eduAccepted) &&
      !_submitting;

  Future<void> _confirm() async {
    if (!_canConfirm) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final auth = context.read<AuthProvider>();
    final result = widget.communityRulesOnly
        ? await auth.acceptCommunityRules()
        : await auth.acceptRequiredLegalConsents(
              includeEduDataConsent: _requiresEduConsent && _eduAccepted,
            );
    if (!mounted) return;
    if (result.success) {
      if (widget.communityRulesOnly) {
        Navigator.of(context).pop(true);
      } else {
        Navigator.of(context).pop();
      }
      return;
    }
    setState(() {
      _submitting = false;
      _error = result.errorMessage ?? '协议确认失败，请稍后重试';
      if (result.errorCode == 'edu_data_consent_required') {
        // 本地教务状态可能过期，按服务端要求展示独立勾选项，避免只有报错却无法补签。
        _serverRequiresEduConsent = true;
      }
    });
  }

  Future<void> _logout() async {
    setState(() => _submitting = true);
    await context.read<AuthProvider>().logout();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(widget.communityRulesOnly ? '请确认社区规则' : '请确认协议与隐私政策'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.communityRulesOnly
                  ? '首次点赞、评论、发送私信或发布内容前，请阅读并确认社区规则。'
                  : '继续使用前，请阅读并确认以下协议与说明。'),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('required-consent-documents'),
                onPressed: _submitting
                    ? null
                    : () => LegalDocumentsScreen.open(context,
                        documentId:
                            widget.communityRulesOnly ? 'community_rules' : null),
                icon: const Icon(Icons.description_outlined),
                label: Text(widget.communityRulesOnly ? '查看社区规则' : '查看协议与隐私政策'),
              ),
              CheckboxListTile(
                key: const ValueKey('required-general-consents'),
                value: _generalAccepted,
                onChanged: _submitting
                    ? null
                    : (value) =>
                        setState(() => _generalAccepted = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(widget.communityRulesOnly
                    ? '我已阅读并同意社区规则'
                    : '我已阅读并确认用户协议和隐私政策'),
              ),
              if (_requiresEduConsent)
                CheckboxListTile(
                  key: const ValueKey('required-edu-consent'),
                  value: _eduAccepted,
                  onChanged: _submitting
                      ? null
                      : (value) =>
                          setState(() => _eduAccepted = value ?? false),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('我已阅读并同意教务数据专项授权'),
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('required-consent-logout'),
            onPressed: _submitting
                ? null
                : widget.communityRulesOnly
                    ? () => Navigator.of(context).pop(false)
                    : _logout,
            child: Text(widget.communityRulesOnly ? '暂不同意' : '退出登录'),
          ),
          FilledButton(
            key: const ValueKey('required-consent-confirm'),
            onPressed: _canConfirm ? _confirm : null,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('确认并继续'),
          ),
        ],
      ),
    );
  }
}
