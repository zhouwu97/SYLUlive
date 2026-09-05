import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../application/academic_session_controller.dart';
import '../application/academic_login_coordinator.dart';
import '../domain/academic_failure.dart';

/// 本机直连教务登录入口，包含登录、验证码和明确的本地数据授权状态。
final class AcademicLoginDialog extends StatefulWidget {
  const AcademicLoginDialog({
    required this.controller,
    this.coordinator,
    this.initialStudentId,
    this.initialSaveCredentials = false,
    super.key,
  });

  final AcademicSessionController controller;
  final AcademicLoginCoordinator? coordinator;
  final String? initialStudentId;
  final bool initialSaveCredentials;

  static Future<bool?> show(
    BuildContext context, {
    required AcademicSessionController controller,
    AcademicLoginCoordinator? coordinator,
    String? initialStudentId,
    bool initialSaveCredentials = false,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AcademicLoginDialog(
        controller: controller,
        coordinator: coordinator,
        initialStudentId: initialStudentId,
        initialSaveCredentials: initialSaveCredentials,
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
  late final AcademicLoginCoordinator _coordinator;
  final _formKey = GlobalKey<FormState>();
  bool _saveCredentials = false;
  bool _saveAcademicData = false;
  bool _usingSavedCredential = false;
  bool _loadingPreferences = true;
  String? _savedCredentialStudentId;
  String? _coordinatorMessage;

  AcademicSessionController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _studentIdController =
        TextEditingController(text: widget.initialStudentId ?? '');
    _passwordController = TextEditingController();
    _captchaController = TextEditingController();
    _coordinator = widget.coordinator ??
        AcademicLoginCoordinator(controller: widget.controller);
    _studentIdController.addListener(_handleStudentIdChanged);
    _loadSavedState();
  }

  @override
  void dispose() {
    _studentIdController.dispose();
    _passwordController.dispose();
    _captchaController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedState() async {
    final saved = await _coordinator.readSavedCredential();
    final preferences = await _coordinator.loadPreferences();
    if (!mounted) return;
    final initial = _studentIdController.text.trim();
    final canUseSaved = preferences.saveCredentials &&
        saved != null &&
        (initial.isEmpty || initial == saved.studentId.trim());
    setState(() {
      _loadingPreferences = false;
      _saveCredentials = widget.initialSaveCredentials ||
          (preferences.saveCredentials && saved != null);
      _saveAcademicData = !kIsWeb && preferences.saveAcademicData;
      _savedCredentialStudentId = saved?.studentId.trim();
      _usingSavedCredential = canUseSaved;
      if (canUseSaved) _studentIdController.text = saved.studentId;
    });
  }

  void _handleStudentIdChanged() {
    final savedId = _savedCredentialStudentId;
    if (!_usingSavedCredential || savedId == null) return;
    if (_studentIdController.text.trim() != savedId) {
      setState(() {
        _usingSavedCredential = false;
        _passwordController.clear();
      });
    }
  }

  Future<void> _submitLogin() async {
    if (!_usingSavedCredential &&
        !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final password = _passwordController.text;
    // 提交前清除 UI 控制器中的密码；验证码续登所需的密码只由 POC
    // 客户端在内存 pending 会话中短暂保留。
    _passwordController.clear();
    final result = await _coordinator.login(
      studentId: _studentIdController.text.trim(),
      password: password,
      saveCredentials: _saveCredentials,
      saveAcademicData: _saveAcademicData,
      useSavedCredential: _usingSavedCredential,
    );
    if (!mounted) return;
    if (result.isSuccess && _controller.isProfileLoaded) {
      Navigator.of(context).pop(true);
    } else if (result.message != null) {
      setState(() => _coordinatorMessage = result.message);
    }
  }

  Future<void> _retryProfile() async {
    await _controller.loadProfile();
    if (!mounted) return;
    if (_controller.isProfileLoaded) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _submitCaptcha() async {
    if (_captchaController.text.trim().isEmpty) return;
    final result = await _coordinator.continueLoginWithCaptcha(
      code: _captchaController.text.trim(),
    );
    if (!mounted) return;
    if (result.isSuccess && _controller.isProfileLoaded) {
      Navigator.of(context).pop(true);
    } else if (result.message != null) {
      setState(() => _coordinatorMessage = result.message);
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
        final profileError = _controller.hasProfileError;
        final failure = _controller.failure ??
            (profileError
                ? const AcademicFailure(
                    kind: AcademicFailureKind.unexpected,
                    message: '教务资料加载失败，请重试',
                    code: 'ACADEMIC_PROFILE_FAILED',
                  )
                : null);

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
                      '教务登录仅在当前设备完成，密码和教务数据不会上传沈理校园服务器。',
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
                      decoration: InputDecoration(
                        labelText: '教务密码',
                        prefixIcon: const Icon(Icons.lock_outline),
                        hintText: _usingSavedCredential ? '已安全保存' : null,
                      ),
                      validator: (value) =>
                          value == null || value.isEmpty ? '请输入教务密码' : null,
                      onFieldSubmitted: (_) {
                        if (!isBusy && !awaitingCaptcha) _submitLogin();
                      },
                    ),
                    SwitchListTile(
                      value: _saveCredentials,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('在本机安全保存登录凭据'),
                      subtitle: Text(
                        _usingSavedCredential
                            ? '学号和密码仅保存在设备系统安全存储中'
                            : '用于下次自动重新登录，不上传沈理校园服务器',
                      ),
                      onChanged:
                          isBusy || awaitingCaptcha || _loadingPreferences
                              ? null
                              : (value) => setState(
                                    () => _saveCredentials = value,
                                  ),
                    ),
                    SwitchListTile(
                      value: _saveAcademicData,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('在本机保存教务资料'),
                      subtitle: const Text(
                        kIsWeb
                            ? '网页版不会保存教务密码或教务资料'
                            : '课表、成绩等保存到当前 App 账号隔离的本地加密保险箱',
                      ),
                      onChanged: kIsWeb ||
                              isBusy ||
                              awaitingCaptcha ||
                              _loadingPreferences
                          ? null
                          : (value) => setState(
                                () => _saveAcademicData = value,
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
                    if (_coordinatorMessage != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(_coordinatorMessage!),
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
            if (profileError)
              TextButton(
                onPressed: isBusy ? null : _retryProfile,
                child: const Text('重试资料'),
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
                onPressed: isBusy ? null : _submitLogin,
                child: isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('登录教务'),
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
