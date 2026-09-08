import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:jiaowu_dart_poc/jiaowu_dart.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_spacing.dart';
import '../../../screens/legal_documents_screen.dart';
import '../application/academic_session_controller.dart';
import '../application/academic_login_coordinator.dart';
import '../domain/academic_failure.dart';
import '../domain/academic_provider.dart';
import '../domain/academic_repository.dart';

/// 教务登录入口，按实际数据源说明凭据保存方式并取得对应授权。
final class AcademicLoginDialog extends StatefulWidget {
  const AcademicLoginDialog({
    required this.controller,
    this.coordinator,
    this.initialStudentId,
    this.initialSaveCredentials = false,
    this.changeIdentity = false,
    super.key,
  });

  final AcademicSessionController controller;
  final AcademicLoginCoordinator? coordinator;
  final String? initialStudentId;
  final bool initialSaveCredentials;
  final bool changeIdentity;

  static Future<bool?> show(
    BuildContext context, {
    required AcademicSessionController controller,
    AcademicLoginCoordinator? coordinator,
    String? initialStudentId,
    bool initialSaveCredentials = false,
    bool changeIdentity = false,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AcademicLoginDialog(
        controller: controller,
        coordinator: coordinator,
        initialStudentId: initialStudentId,
        initialSaveCredentials: initialSaveCredentials,
        changeIdentity: changeIdentity,
      ),
    );
  }

  @override
  State<AcademicLoginDialog> createState() => _AcademicLoginDialogState();
}

/// 课表、成绩等本机读取入口共用的会话前置。
///
/// 先尝试 Artifact 或已保存凭据的无感恢复；只有确实需要用户输入时
/// 才打开登录框，避免已绑定身份在读取数据时被误导成“重新绑定”。
Future<bool> ensureAcademicSessionForRead(
  BuildContext context, {
  required AcademicSessionController controller,
  AcademicLoginCoordinator? coordinator,
}) async {
  if (!await controller.remoteAccessAllowed()) return false;
  if (controller.isAuthenticated) return true;

  final generation = controller.contextGeneration;
  final appUserId = controller.appUserId;
  final loginCoordinator =
      coordinator ?? AcademicLoginCoordinator(controller: controller);
  final outcome = await loginCoordinator.ensureAuthenticated();
  if (!controller.isCurrentContext(
    generation: generation,
    appUserId: appUserId,
  )) {
    return false;
  }
  if (controller.isAuthenticated) return true;
  if (!context.mounted ||
      outcome.kind == AcademicLoginOutcomeKind.contextChanged ||
      outcome.kind == AcademicLoginOutcomeKind.networkFailure ||
      outcome.kind == AcademicLoginOutcomeKind.failure) {
    return false;
  }

  final success = await AcademicLoginDialog.show(
    context,
    controller: controller,
    coordinator: loginCoordinator,
  );
  if (!controller.isCurrentContext(
    generation: generation,
    appUserId: appUserId,
  )) {
    return false;
  }
  return success == true && controller.isAuthenticated;
}

class _AcademicLoginDialogState extends State<AcademicLoginDialog> {
  late final TextEditingController _studentIdController;
  late final TextEditingController _passwordController;
  late final TextEditingController _captchaController;
  late final AcademicLoginCoordinator _coordinator;
  final _formKey = GlobalKey<FormState>();
  bool _consentAccepted = false;
  bool _saveCredentials = false;
  bool _saveAcademicData = false;
  bool _usingSavedCredential = false;
  bool _loadingPreferences = true;
  bool _submitting = false;
  String? _savedCredentialStudentId;
  String? _coordinatorMessage;
  CaptchaChallenge? _appliedCaptchaChallenge;
  late AcademicProviderId _selectedProviderId;

  AcademicSessionController get _controller => widget.controller;

  /// 已由服务端确认的身份是登录目标的可信边界；本机会话过期时仍然
  /// 复用它，避免把恢复操作误导成一次新的身份绑定。
  AcademicIdentityKey? get _trustedIdentity {
    final identity = _controller.identity;
    return _controller.hasBoundIdentity && identity?.isValid == true
        ? identity
        : null;
  }

  bool get _identityLocked => !widget.changeIdentity && _trustedIdentity != null;

  @override
  void initState() {
    super.initState();
    final trustedIdentity = _trustedIdentity;
    _studentIdController = TextEditingController(
      text: trustedIdentity?.studentId ?? widget.initialStudentId ?? '',
    );
    _passwordController = TextEditingController();
    _captchaController = TextEditingController();
    _selectedProviderId = trustedIdentity?.providerId ??
        widget.controller.providerId ??
        AcademicProviderId.syluUndergraduate;
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
    if (_controller.sourceKind == AcademicSourceKind.legacy || widget.changeIdentity) {
      // 绑定授权不代表同意开启本机缓存，沿用当前 App 账号的独立选择。
      final preferences = await _coordinator.loadPreferences();
      if (!mounted) return;
      setState(() {
        _loadingPreferences = false;
        _saveCredentials = false;
        _saveAcademicData = !kIsWeb && preferences.saveAcademicData;
      });
      return;
    }
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
    if (_loadingPreferences || _submitting) return;
    if (_controller.sourceKind == AcademicSourceKind.legacy &&
        !_consentAccepted) {
      return;
    }
    if (!_usingSavedCredential &&
        !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final password = _passwordController.text;
    // 验证码和临时故障仍属于本次登录，保留遮蔽输入以支持继续和重试。
    setState(() => _submitting = true);
    final result = await _coordinator.login(
      studentId: _studentIdController.text.trim(),
      password: password,
      saveCredentials: _saveCredentials,
      saveAcademicData: _saveAcademicData,
      useSavedCredential: _usingSavedCredential,
      changeIdentity: widget.changeIdentity,
      providerId: (_controller.sourceKind == AcademicSourceKind.legacy || widget.changeIdentity)
          ? _selectedProviderId
          : _controller.providerId,
    ).whenComplete(() {
      if (mounted) setState(() => _submitting = false);
    });
    if (!mounted) return;
    if (result.isSuccess) _passwordController.clear();
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
    if (widget.changeIdentity) {
      _coordinator.cancelIdentityVerification();
    } else {
      await _controller.resetSession();
    }
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final isBusy = _controller.isBusy || _submitting;
        final awaitingCaptcha = _controller.isAwaitingCaptcha;
        final challenge = _controller.captchaChallenge;
        _applyCaptchaSuggestion(challenge);
        final profileError = _controller.hasProfileError;
        final failure = _controller.failure ??
            (profileError
                ? const AcademicFailure(
                    kind: AcademicFailureKind.unexpected,
                    message: '教务资料加载失败，请重试',
                    code: 'ACADEMIC_PROFILE_FAILED',
                  )
                : null);
        final serverBinding =
            _controller.sourceKind == AcademicSourceKind.legacy;
        final selectingProvider =
            widget.changeIdentity || (serverBinding && _controller.providerId == null);

        return AlertDialog(
          title: Text(widget.changeIdentity ? '更换学生身份' : (serverBinding ? '绑定教务账号' : '本机直连教务')),
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
                      widget.changeIdentity
                          ? '验证新身份成功后才会更换绑定，并清除旧身份的本机教务资料。验证失败会保留原身份。'
                          : serverBinding
                          ? '绑定只确认你在学校的教务身份。新身份路径不会保存学校密码或 Cookie，服务端按授权身份拉取可用教务数据；旧部署可能暂时使用兼容绑定。'
                          : '密码用于学校登录；会话材料仅以加密形式保存在本机，可随时断开或清除。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    if (selectingProvider) ...[
                      DropdownButtonFormField<AcademicProviderId>(
                        initialValue: _selectedProviderId,
                        decoration: const InputDecoration(
                          labelText: '教务类型',
                          prefixIcon: Icon(Icons.school_outlined),
                        ),
                        items: AcademicProviderId.values
                            .map(
                              (provider) => DropdownMenuItem(
                                value: provider,
                                child: Text(provider.displayName),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: isBusy || awaitingCaptcha
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => _selectedProviderId = value);
                                }
                              },
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    if (_identityLocked) ...[
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '教务类型',
                          prefixIcon: Icon(Icons.school_outlined),
                          helperText: '身份已由学校教务确认，登录时不可切换类型',
                        ),
                        child: Text(_trustedIdentity!.providerId.displayName),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],
                    TextFormField(
                      controller: _studentIdController,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      enabled: !isBusy && !awaitingCaptcha,
                      readOnly: _identityLocked,
                      decoration: InputDecoration(
                        labelText: '教务学号',
                        prefixIcon: const Icon(Icons.badge_outlined),
                        helperText: _identityLocked ? '已绑定身份：学号由服务端确认' : null,
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
                        helperText: awaitingCaptcha ? '密码已在本次登录中保留，无需重新输入' : null,
                      ),
                      validator: (value) =>
                          value == null || value.isEmpty ? '请输入教务密码' : null,
                      onFieldSubmitted: (_) {
                        if (!isBusy && !awaitingCaptcha) _submitLogin();
                      },
                    ),
                    if (!serverBinding)
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
                    if (!serverBinding)
                      SwitchListTile(
                        value: _saveAcademicData,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('在本机保存教务资料'),
                        subtitle: const Text(
                          kIsWeb
                              ? '网页版不会保存教务密码或教务资料'
                              : '教务资料保存到当前 App 账号隔离的本地加密保险箱',
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
                    if (serverBinding)
                      CheckboxListTile(
                        value: _consentAccepted,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('我已阅读并同意教务数据专项授权'),
                        onChanged: isBusy || awaitingCaptcha
                            ? null
                            : (value) => setState(
                                () => _consentAccepted = value ?? false),
                      ),
                    if (serverBinding)
                      TextButton(
                        onPressed: isBusy
                            ? null
                            : () => LegalDocumentsScreen.open(
                                  context,
                                  documentId: 'edu_data_consent',
                                ),
                        child: const Text('查看教务数据专项授权'),
                      ),
                    if (awaitingCaptcha) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _CaptchaPanel(
                        challenge: challenge,
                        controller: _captchaController,
                        enabled: !isBusy,
                        onRefresh: _coordinator.refreshCaptcha,
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
                style: FilledButton.styleFrom(
                  textStyle: Theme.of(context).textTheme.labelLarge,
                  minimumSize: const Size(64, 44),
                ),
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
                style: FilledButton.styleFrom(
                  textStyle: Theme.of(context).textTheme.labelLarge,
                  minimumSize: const Size(64, 44),
                ),
                onPressed: isBusy ||
                        _loadingPreferences ||
                        (serverBinding && !_consentAccepted)
                    ? null
                    : _submitLogin,
                child: isBusy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(widget.changeIdentity ? '确认更换并验证' : (serverBinding ? '同意并绑定' : '登录教务')),
              ),
          ],
        );
      },
    );
  }

  /// 每张新图片填入对应候选，同一图片内保留用户修改；模型概率不作为自动登录条件。
  void _applyCaptchaSuggestion(CaptchaChallenge? challenge) {
    if (challenge == null || identical(challenge, _appliedCaptchaChallenge)) return;
    final previous = _appliedCaptchaChallenge;
    final oldText = _captchaController.text;
    final suggestion = challenge.suggestedCode?.trim() ?? '';
    _appliedCaptchaChallenge = challenge;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(_controller.captchaChallenge, challenge)) {
        return;
      }
      if (_captchaController.text != oldText) return;
      if (previous == null && oldText.trim().isNotEmpty) return;
      // 新图片必须替换旧验证码；同一图片内用户的手动修改不覆盖。
      _captchaController.value = TextEditingValue(
        text: suggestion,
        selection: TextSelection.collapsed(offset: suggestion.length),
      );
    });
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
          decoration: InputDecoration(
            labelText: '验证码',
            helperText: challenge?.suggestedCode == null
                ? null
                : '本机已填入候选：${challenge!.suggestedCode}，请核对图片后提交',
            prefixIcon: const Icon(Icons.verified_outlined),
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
