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

class RequiredLegalConsentDialog extends StatefulWidget {
  final bool requiresEduDataConsent;

  const RequiredLegalConsentDialog({
    super.key,
    required this.requiresEduDataConsent,
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

  bool get _canConfirm =>
      _generalAccepted &&
      (!widget.requiresEduDataConsent || _eduAccepted) &&
      !_submitting;

  Future<void> _confirm() async {
    if (!_canConfirm) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final result =
        await context.read<AuthProvider>().acceptRequiredLegalConsents(
              includeEduDataConsent: widget.requiresEduDataConsent,
            );
    if (!mounted) return;
    if (result.success) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _submitting = false;
      _error = result.errorMessage ?? '协议确认失败，请稍后重试';
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
        title: const Text('请确认协议与隐私政策'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('继续使用前，请阅读并确认以下协议与说明。'),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const ValueKey('required-consent-documents'),
                onPressed: _submitting
                    ? null
                    : () => LegalDocumentsScreen.open(context),
                icon: const Icon(Icons.description_outlined),
                label: const Text('查看协议与隐私政策'),
              ),
              CheckboxListTile(
                key: const ValueKey('required-general-consents'),
                value: _generalAccepted,
                onChanged: _submitting
                    ? null
                    : (value) => setState(
                          () => _generalAccepted = value ?? false,
                        ),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('我已阅读并同意用户协议、隐私政策等 6 项说明'),
              ),
              if (widget.requiresEduDataConsent)
                CheckboxListTile(
                  key: const ValueKey('required-edu-consent'),
                  value: _eduAccepted,
                  onChanged: _submitting
                      ? null
                      : (value) => setState(
                            () => _eduAccepted = value ?? false,
                          ),
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
            onPressed: _submitting ? null : _logout,
            child: const Text('退出登录'),
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
