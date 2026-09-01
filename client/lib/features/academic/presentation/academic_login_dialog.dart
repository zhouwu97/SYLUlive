import 'package:flutter/material.dart';
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../application/academic_session_controller.dart';
import '../domain/academic_failure.dart';

/// 本机直连教务登录入口，包含登录、验证码和明确的本地数据授权状态。
final class AcademicLoginDialog extends StatefulWidget {
  const AcademicLoginDialog({
    required this.controller,
    this.initialStudentId,
    super.key,
  });

  final AcademicSessionController controller;
  final String? initialStudentId;

  static Future<bool?> show(
    BuildContext context, {
    required AcademicSessionController controller,
    String? initialStudentId,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AcademicLoginDialog(
        controller: controller,
        initialStudentId: initialStudentId,
      ),
    );
  }

  @override
  State<AcademicLoginDialog> createState() => _AcademicLoginDialogState();
}

class _AcademicLoginDialogState extends State<AcademicLoginDialog> {
  late final TextEditingController _studentIdController;
  late final TextEditingController _passwordController;
  late final TextEditingController _captchaController;
  final _formKey = GlobalKey<FormState>();
  bool _consentAccepted = false;

  AcademicSessionController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _studentIdController =
        TextEditingController(text: widget.initialStudentId ?? '');
    _passwordController = TextEditingController();
    _captchaController = TextEditingController();
  }

  @override
  void dispose() {
    _studentIdController.dispose();
    _passwordController.dispose();
    _captchaController.dispose();
    super.dispose();
  }

  Future<void> _submitLogin() async {
    if (!_consentAccepted || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final result = await _controller.login(
      studentId: _studentIdController.text.trim(),
      password: _passwordController.text,
    );
    // 初次登录请求完成后不再让 UI 控制器保留密码；验证码续登所需的
    // 密码只由 POC 客户端在内存 pending 会话中短暂保留。
    _passwordController.clear();
    if (!mounted) return;
    if (result is LoginSuccess) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _submitCaptcha() async {
    if (_captchaController.text.trim().isEmpty) return;
    final result = await _controller.continueLoginWithCaptcha(
      code: _captchaController.text.trim(),
    );
    if (!mounted) return;
    if (result is LoginSuccess) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _cancel() async {
    await _controller.resetSession();
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final isBusy = _controller.isBusy;
        final awaitingCaptcha = _controller.isAwaitingCaptcha;
        final challenge = _controller.captchaChallenge;
        final failure = _controller.failure;

        return AlertDialog(
          title: const Text('本机直连教务'),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.68,
            ),
            child: SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '密码只用于本次学校登录，Cookie 仅保存在内存中。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    TextFormField(
                      controller: _studentIdController,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      maxLength: 10,
                      enabled: !isBusy && !awaitingCaptcha,
                      decoration: const InputDecoration(
                        labelText: '教务学号',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? '请输入教务学号'
                              : null,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      enabled: !isBusy && !awaitingCaptcha,
                      decoration: const InputDecoration(
                        labelText: '教务密码',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                      validator: (value) =>
                          value == null || value.isEmpty ? '请输入教务密码' : null,
                      onFieldSubmitted: (_) {
                        if (!isBusy && !awaitingCaptcha) _submitLogin();
                      },
                    ),
                    CheckboxListTile(
                      value: _consentAccepted,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('同意本机保存教务资料'),
                      subtitle: const Text('课程和成绩仅写入当前 App 账号隔离的本地加密保险箱。'),
                      onChanged: isBusy || awaitingCaptcha
                          ? null
                          : (value) => setState(
                                () => _consentAccepted = value ?? false,
                              ),
                    ),
                    if (awaitingCaptcha) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _CaptchaPanel(
                        challenge: challenge,
                        controller: _captchaController,
                        enabled: !isBusy,
                        onRefresh: _controller.refreshCaptcha,
                      ),
                    ],
                    if (failure != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      _FailureMessage(failure: failure),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: isBusy ? null : _cancel,
              child: const Text('取消'),
            ),
            if (awaitingCaptcha)
              FilledButton(
                onPressed: isBusy ? null : _submitCaptcha,
                child: isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('继续登录'),
              )
            else
              FilledButton(
                onPressed: isBusy || !_consentAccepted ? null : _submitLogin,
                child: isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('登录'),
              ),
          ],
        );
      },
    );
  }
}

final class _CaptchaPanel extends StatelessWidget {
  const _CaptchaPanel({
    required this.challenge,
    required this.controller,
    required this.enabled,
    required this.onRefresh,
  });

  final CaptchaChallenge? challenge;
  final TextEditingController controller;
  final bool enabled;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final borderColor = Theme.of(context).colorScheme.outlineVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '请输入验证码',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 160,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.surfaceMutedDark
                    : AppColors.surfaceMutedLight,
                border: Border.all(color: borderColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: challenge == null
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Image.memory(
                      challenge!.imageBytes,
                      gaplessPlayback: true,
                      semanticLabel: '教务验证码图片',
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.broken_image_outlined,
                        semanticLabel: '验证码图片加载失败',
                      ),
                    ),
            ),
            const SizedBox(width: AppSpacing.sm),
            IconButton(
              tooltip: '换一张验证码',
              onPressed: enabled ? onRefresh : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: controller,
          enabled: enabled,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: '验证码',
            prefixIcon: Icon(Icons.verified_outlined),
          ),
        ),
      ],
    );
  }
}

final class _FailureMessage extends StatelessWidget {
  const _FailureMessage({required this.failure});

  final AcademicFailure failure;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color:
            isDark ? AppColors.dangerSurfaceDark : AppColors.dangerSurfaceLight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline,
            size: 20,
            color: AppColors.danger,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              failure.message,
              style: TextStyle(
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimaryLight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
