import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';
import 'legal_documents_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _studentIdController = TextEditingController();
  final _emailController = TextEditingController();
  final _eduPasswordController = TextEditingController(); // 教务密码
  final _appPasswordController = TextEditingController(); // APP密码
  final _nicknameController = TextEditingController(); // 昵称
  final _verifyCodeController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _eduPasswordFocus = FocusNode();
  Timer? _codeCooldownTimer;

  bool _isRegister = false;
  bool _isLoading = false;
  String _registerMode = 'campus';
  int _codeCooldown = 0;
  bool _obscureAppPassword = true;
  bool _obscureEduPassword = true;
  bool _userAgreementAccepted = false;
  bool _privacyPolicyAccepted = false;
  final bool _communityRulesAccepted = false;
  final bool _minorProtectionAccepted = false;
  final bool _contentComplaintAccepted = false;
  final bool _sdkDisclosureAccepted = false;
  bool _eduDataConsentAccepted = false;

  @override
  void dispose() {
    _studentIdController.dispose();
    _emailController.dispose();
    _eduPasswordController.dispose();
    _appPasswordController.dispose();
    _nicknameController.dispose();
    _verifyCodeController.dispose();
    _eduPasswordFocus.dispose();
    _codeCooldownTimer?.cancel();
    super.dispose();
  }

  String? _validateAppPassword(String? v) {
    if (v == null || v.isEmpty) return '请输入密码';
    if (v.length < 8) return '密码至少8个字符';
    if (!RegExp(r'[0-9]').hasMatch(v)) return '密码需包含数字';
    if (!RegExp(r'[a-zA-Z]').hasMatch(v)) return '密码需包含字母';
    return null;
  }

  bool get _isEmailRegister => _isRegister && _registerMode == 'email';

  bool get _hasRequiredRegistrationConsents =>
      _userAgreementAccepted &&
      _privacyPolicyAccepted &&
      (_isEmailRegister || _eduDataConsentAccepted);

  RegistrationConsents get _registrationConsents => RegistrationConsents(
        userAgreementAccepted: _userAgreementAccepted,
        privacyPolicyAccepted: _privacyPolicyAccepted,
        communityRulesAccepted: _communityRulesAccepted,
        minorProtectionAccepted: _minorProtectionAccepted,
        contentComplaintAccepted: _contentComplaintAccepted,
        sdkDisclosureAccepted: _sdkDisclosureAccepted,
        eduDataConsentAccepted: _eduDataConsentAccepted,
      );

  InputDecoration _inputDecoration(
    BuildContext context, {
    required String label,
    required IconData icon,
    String? helperText,
    Widget? suffixIcon,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border =
        isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE4DA);
    final accent = isDark ? const Color(0xFF80C4FC) : const Color(0xFF76C4FF);
    final subText = isDark ? Colors.white70 : const Color(0xFF747B82);

    return InputDecoration(
      labelText: label,
      helperText: helperText,
      filled: true,
      fillColor: isDark ? const Color(0xFF1A1D21) : const Color(0xFFFFFCF8),
      prefixIcon: Icon(icon, color: subText),
      suffixIcon: suffixIcon,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: accent, width: 1.2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      helperStyle: TextStyle(color: subText, fontSize: 11.5),
    );
  }

  Future<void> _showLoginLimitedDialog(String message) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF80C4FC) : const Color(0xFF76C4FF);
    final subText = isDark ? Colors.white70 : const Color(0xFF747B82);
    final cardBg = isDark ? const Color(0xFF1E2226) : Colors.white;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('登录受限'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _showForgotPasswordDialog();
            },
            style: TextButton.styleFrom(foregroundColor: subText),
            child: const Text('去忘记密码'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            style: FilledButton.styleFrom(backgroundColor: accent),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isRegister && !_hasRequiredRegistrationConsents) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先阅读并确认全部必选协议与授权')),
      );
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();

    final authProvider = context.read<AuthProvider>();
    AuthResult result;

    if (mounted) setState(() => _isLoading = true);

    if (_isRegister) {
      if (_registerMode == 'email') {
        result = await authProvider.registerWithEmail(
          _emailController.text.trim(),
          _verifyCodeController.text.trim(),
          _appPasswordController.text,
          nickname: _nicknameController.text.trim().isNotEmpty
              ? _nicknameController.text.trim()
              : null,
          consents: _registrationConsents,
        );
      } else {
        result = await authProvider.registerWithEdu(
          _studentIdController.text.trim(),
          _appPasswordController.text,
          nickname: _nicknameController.text.trim().isNotEmpty
              ? _nicknameController.text.trim()
              : null,
          eduPassword: _eduPasswordController.text,
          consents: _registrationConsents,
        );
      }
    } else {
      final account = _studentIdController.text.trim();
      result = await authProvider.login(account, _appPasswordController.text);
    }

    if (mounted) setState(() => _isLoading = false);

    if (result.success && mounted) {
      // 先设置 Authorization header，再刷新 EduProvider
      if (authProvider.token != null) {
        authProvider.dio.options.headers['Authorization'] =
            'Bearer ${authProvider.token}';
        context.read<EduProvider>().setUserId(authProvider.user!.id.toString());
      }
      Navigator.pop(context);
    } else if (mounted && result.errorMessage != null) {
      if (!_isRegister && result.statusCode == 429) {
        await _showLoginLimitedDialog(result.errorMessage!);
        return;
      }
      if (!_isRegister && result.errorMessage!.contains('尚未注册')) {
        FocusManager.instance.primaryFocus?.unfocus();
        if (mounted) {
          setState(() {
            _isRegister = true;
            _eduPasswordController.clear();
            _appPasswordController.clear();
            _nicknameController.clear();
          });
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _eduPasswordFocus.requestFocus();
          }
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.errorMessage!),
          backgroundColor: Colors.red.shade600,
        ),
      );
    }
  }

  Future<void> _sendEmailCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先输入有效邮箱')));
      return;
    }
    if (mounted) setState(() => _isLoading = true);
    final result =
        await context.read<AuthProvider>().requestEmailRegistrationCode(email);
    if (!mounted) return;
    setState(() => _isLoading = false);
    if (result.success) {
      _codeCooldownTimer?.cancel();
      if (mounted) setState(() => _codeCooldown = 60);
      _codeCooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || _codeCooldown <= 1) {
          timer.cancel();
          if (mounted) setState(() => _codeCooldown = 0);
          return;
        }
        if (mounted) setState(() => _codeCooldown -= 1);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('验证码已发送到邮箱'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.errorMessage ?? '发送失败'),
          backgroundColor: Colors.red.shade600,
        ),
      );
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final studentIdController = TextEditingController(
      text: _studentIdController.text.trim(),
    );
    final emailController = TextEditingController();
    final codeController = TextEditingController();
    final eduPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var isSubmitting = false;
    var useEmail = true;
    var obscureEduPassword = true;
    var obscureNewPassword = true;
    var obscureConfirmPassword = true;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setLocalState) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final accent =
                isDark ? const Color(0xFF80C4FC) : const Color(0xFF76C4FF);
            final subText = isDark ? Colors.white70 : const Color(0xFF747B82);
            final cardBg = isDark ? const Color(0xFF1E2226) : Colors.white;

            return AlertDialog(
              backgroundColor: cardBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              title: const Text('忘记密码'),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        useEmail
                            ? '通过已绑定邮箱验证后重置 APP 密码。'
                            : '通过已认证学号和教务密码验证后重置 APP 密码。',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: Colors.grey[700],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: true, label: Text('邮箱验证')),
                          ButtonSegment(value: false, label: Text('教务验证')),
                        ],
                        selected: {useEmail},
                        onSelectionChanged: (selection) =>
                            setLocalState(() => useEmail = selection.first),
                      ),
                      const SizedBox(height: 12),
                      if (useEmail) ...[
                        TextFormField(
                          controller: emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: _inputDecoration(
                            context,
                            label: '邮箱',
                            icon: Icons.email_outlined,
                          ),
                          validator: (value) =>
                              value == null || !value.contains('@')
                                  ? '请输入有效邮箱'
                                  : null,
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: codeController,
                                keyboardType: TextInputType.number,
                                decoration: _inputDecoration(
                                  context,
                                  label: '验证码',
                                  icon: Icons.verified_outlined,
                                ),
                                validator: (value) => value?.trim().length != 6
                                    ? '请输入 6 位验证码'
                                    : null,
                              ),
                            ),
                            IconButton(
                              tooltip: '发送验证码',
                              onPressed: () async {
                                final result = await context
                                    .read<AuthProvider>()
                                    .requestEmailPasswordResetCode(
                                        emailController.text.trim());
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(result.success
                                            ? '验证码已发送'
                                            : result.errorMessage ?? '发送失败')),
                                  );
                                }
                              },
                              icon: const Icon(Icons.send_outlined),
                            ),
                          ],
                        ),
                      ] else ...[
                        TextFormField(
                          controller: studentIdController,
                          maxLength: 10,
                          keyboardType: TextInputType.number,
                          decoration: _inputDecoration(
                            context,
                            label: '学号',
                            icon: Icons.person_outline,
                          ).copyWith(counterText: ''),
                          validator: (value) =>
                              value?.trim().length != 10 ? '请输入 10 位学号' : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: eduPasswordController,
                          obscureText: obscureEduPassword,
                          decoration: _inputDecoration(
                            context,
                            label: '教务密码',
                            icon: Icons.school_outlined,
                            suffixIcon: IconButton(
                              onPressed: () => setLocalState(
                                () => obscureEduPassword = !obscureEduPassword,
                              ),
                              icon: Icon(obscureEduPassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined),
                            ),
                          ),
                          validator: (value) =>
                              value?.isEmpty == true ? '请输入教务密码' : null,
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: newPasswordController,
                        obscureText: obscureNewPassword,
                        decoration: _inputDecoration(
                          context,
                          label: '新的软件密码',
                          icon: Icons.lock_reset,
                          helperText: '8位以上，需包含数字和字母',
                          suffixIcon: IconButton(
                            onPressed: () => setLocalState(
                              () => obscureNewPassword = !obscureNewPassword,
                            ),
                            icon: Icon(
                              obscureNewPassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                        validator: _validateAppPassword,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: confirmPasswordController,
                        obscureText: obscureConfirmPassword,
                        decoration: _inputDecoration(
                          context,
                          label: '确认新密码',
                          icon: Icons.check_circle_outline,
                          suffixIcon: IconButton(
                            onPressed: () => setLocalState(
                              () => obscureConfirmPassword =
                                  !obscureConfirmPassword,
                            ),
                            icon: Icon(
                              obscureConfirmPassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                        validator: (v) {
                          if (v == null || v.isEmpty) return '请再次输入新密码';
                          if (v != newPasswordController.text) {
                            return '两次输入的密码不一致';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      isSubmitting ? null : () => Navigator.pop(dialogContext),
                  style: TextButton.styleFrom(foregroundColor: subText),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: isSubmitting
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setLocalState(() => isSubmitting = true);
                          final authProvider = context.read<AuthProvider>();
                          final result = useEmail
                              ? await authProvider.resetPasswordWithEmail(
                                  email: emailController.text.trim(),
                                  code: codeController.text.trim(),
                                  newPassword: newPasswordController.text,
                                )
                              : await authProvider.resetPasswordWithEdu(
                                  studentIdController.text.trim(),
                                  eduPasswordController.text,
                                  newPasswordController.text,
                                );
                          if (!mounted) return;
                          if (result.success) {
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                            if (mounted) {
                              setState(() {
                                _isRegister = false;
                                _studentIdController.text = useEmail
                                    ? emailController.text.trim()
                                    : studentIdController.text.trim();
                                _appPasswordController.clear();
                                _eduPasswordController.clear();
                              });
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('密码已重置，请使用新密码登录'),
                                backgroundColor: Colors.green,
                              ),
                            );
                          } else {
                            if (dialogContext.mounted) {
                              setLocalState(() => isSubmitting = false);
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(result.errorMessage ?? '密码重置失败'),
                                backgroundColor: Colors.red.shade600,
                              ),
                            );
                          }
                        },
                  style: FilledButton.styleFrom(backgroundColor: accent),
                  child: isSubmitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('确认重置'),
                ),
              ],
            );
          },
        );
      },
    );

    studentIdController.dispose();
    emailController.dispose();
    codeController.dispose();
    eduPasswordController.dispose();
    newPasswordController.dispose();
    confirmPasswordController.dispose();
  }

  Widget _buildRegisterSegment(String value, String label, Color accent,
      Color accentSoft, Color border, Color subText) {
    final isSelected = _registerMode == value;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          FocusManager.instance.primaryFocus?.unfocus();
          if (mounted) {
            setState(() {
              _registerMode = value;
              _appPasswordController.clear();
              _eduPasswordController.clear();
              _verifyCodeController.clear();
            });
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isSelected ? accent : border,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? accent : subText,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = isDark ? const Color(0xFF101219) : const Color(0xFFFFFAF4);
    final cardBg = isDark ? const Color(0xFF1E2226) : Colors.white;
    final accent = isDark ? const Color(0xFF80C4FC) : const Color(0xFF76C4FF);
    final accentSoft = accent.withValues(alpha: 0.12);
    final border =
        isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFECE4DA);
    final text = isDark ? Colors.white : const Color(0xFF1F2328);
    final subText = isDark ? Colors.white70 : const Color(0xFF747B82);

    return Scaffold(
      backgroundColor: pageBg,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: SafeArea(
          child: Stack(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 40),
                    // Hero
                    Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: [
                            if (!isDark)
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.05),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.asset(
                          'assets/images/mingfeng.png',
                          width: 64,
                          height: 64,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '沈理校园',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: text,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '校园互助社交平台',
                      style: TextStyle(
                        fontSize: 13,
                        color: subText,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),

                    // Card
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: border),
                        boxShadow: [
                          if (!isDark)
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.02),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                        ],
                      ),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_isRegister) ...[
                              Row(
                                children: [
                                  _buildRegisterSegment('campus', '在校生注册',
                                      accent, accentSoft, border, subText),
                                  const SizedBox(width: 12),
                                  _buildRegisterSegment('email', '邮箱注册', accent,
                                      accentSoft, border, subText),
                                ],
                              ),
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: accentSoft,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: accent.withValues(alpha: 0.16),
                                  ),
                                ),
                                child: Text(
                                  _isEmailRegister
                                      ? '邮箱用于登录和找回 APP 密码。完成教务绑定后，学号将成为主账号，当前邮箱仍可使用。'
                                      : '在校生使用学号与教务密码完成认证，注册成功后可使用校园全部功能。',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    height: 1.45,
                                    color: isDark
                                        ? accent
                                        : const Color(0xFF0F5A52),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            TextFormField(
                              controller: _isEmailRegister
                                  ? _emailController
                                  : _studentIdController,
                              maxLength: (!_isRegister || _isEmailRegister)
                                  ? 254
                                  : 20,
                              keyboardType: (!_isRegister || _isEmailRegister)
                                  ? TextInputType.emailAddress
                                  : TextInputType.text,
                              decoration: _inputDecoration(
                                context,
                                label: _isRegister
                                    ? (_isEmailRegister ? '邮箱' : '学号')
                                    : '学号 / 邮箱',
                                icon: Icons.person_outline,
                                helperText: _isRegister
                                    ? (_isEmailRegister
                                        ? '用于登录和找回 APP 密码'
                                        : '仅在校生使用学号注册')
                                    : '已认证学生可用学号或已绑定邮箱登录',
                              ).copyWith(counterText: ''),
                              validator: (v) {
                                if (v == null || v.isEmpty) {
                                  if (_isRegister) {
                                    return _isEmailRegister ? '请输入邮箱' : '请输入学号';
                                  }
                                  return '请输入学号或邮箱';
                                }
                                if (_isEmailRegister && !v.contains('@')) {
                                  return '请输入有效邮箱';
                                }
                                return null;
                              },
                            ),

                            if (_isRegister) ...[
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _nicknameController,
                                decoration: _inputDecoration(
                                  context,
                                  label: '昵称（选填）',
                                  icon: Icons.badge_outlined,
                                  helperText: '将显示在帖子和评论中',
                                ),
                              ),
                              const SizedBox(height: 16),
                              if (_registerMode == 'campus')
                                TextFormField(
                                  controller: _eduPasswordController,
                                  focusNode: _eduPasswordFocus,
                                  obscureText: _obscureEduPassword,
                                  decoration: _inputDecoration(
                                    context,
                                    label: '教务密码',
                                    icon: Icons.lock_outline,
                                    helperText: '用于验证学号真实性',
                                    suffixIcon: IconButton(
                                      onPressed: () => setState(() {
                                        _obscureEduPassword =
                                            !_obscureEduPassword;
                                      }),
                                      icon: Icon(
                                        _obscureEduPassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                    ),
                                  ),
                                  validator: (v) => (v == null || v.isEmpty)
                                      ? '请输入教务密码'
                                      : null,
                                )
                              else
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextFormField(
                                        controller: _verifyCodeController,
                                        keyboardType: TextInputType.number,
                                        decoration: _inputDecoration(
                                          context,
                                          label: '验证码',
                                          icon: Icons.verified_outlined,
                                          helperText: '10 分钟内有效',
                                        ),
                                        validator: (v) =>
                                            (v == null || v.trim().length != 6)
                                                ? '请输入6位验证码'
                                                : null,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    SizedBox(
                                      height: 52,
                                      child: FilledButton.tonal(
                                        onPressed:
                                            (_isLoading || _codeCooldown > 0)
                                                ? null
                                                : _sendEmailCode,
                                        style: FilledButton.styleFrom(
                                            backgroundColor: accentSoft,
                                            foregroundColor: accent,
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(16))),
                                        child: Text(
                                          _codeCooldown > 0
                                              ? '${_codeCooldown}s'
                                              : '发送验证码',
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                            ],

                            const SizedBox(height: 16),
                            TextFormField(
                              controller: _appPasswordController,
                              obscureText: _obscureAppPassword,
                              decoration: _inputDecoration(
                                context,
                                label: _isRegister ? 'APP密码' : '密码',
                                icon: Icons.lock_outline,
                                helperText:
                                    _isRegister ? '8位以上，需包含数字和字母' : null,
                                suffixIcon: IconButton(
                                  onPressed: () => setState(() {
                                    _obscureAppPassword = !_obscureAppPassword;
                                  }),
                                  icon: Icon(
                                    _obscureAppPassword
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                              ),
                              validator: _isRegister
                                  ? _validateAppPassword
                                  : (v) =>
                                      (v == null || v.isEmpty) ? '请输入密码' : null,
                            ),

                            if (!_isRegister) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: _isLoading
                                      ? null
                                      : _showForgotPasswordDialog,
                                  style: TextButton.styleFrom(
                                      foregroundColor: accent),
                                  child: const Text('忘记密码？'),
                                ),
                              ),
                            ] else ...[
                              const SizedBox(height: 12),
                              _buildConsentSection(context, subText),
                              const SizedBox(height: 20),
                            ],

                            // Submit Button
                            Consumer<AuthProvider>(
                              builder: (context, auth, child) => SizedBox(
                                height: 52,
                                child: FilledButton(
                                  onPressed: _isLoading ? null : _submit,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: accent,
                                    disabledBackgroundColor:
                                        accent.withValues(alpha: 0.38),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                    ),
                                  ),
                                  child: _isLoading
                                      ? const SizedBox(
                                          height: 18,
                                          width: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Text(
                                          _isRegister ? '注册' : '登录',
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            TextButton(
                              onPressed: () {
                                FocusManager.instance.primaryFocus?.unfocus();
                                if (mounted) {
                                  setState(() {
                                    _isRegister = !_isRegister;
                                    _eduPasswordController.clear();
                                    _nicknameController.clear();
                                    _appPasswordController.clear();
                                    _verifyCodeController.clear();
                                  });
                                }
                              },
                              style: TextButton.styleFrom(
                                  foregroundColor: subText),
                              child:
                                  Text(_isRegister ? '已有账号？去登录' : '没有账号？去注册'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Skip
              Positioned(
                top: 12,
                right: 16,
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(foregroundColor: subText),
                  child: const Text('跳过'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConsentSection(BuildContext context, Color subText) {
    return Column(
      key: const ValueKey('registration-consent-panel'),
      children: [
        _buildConsentItem(
          context,
          checkboxKey: const ValueKey('registration-user-agreement'),
          value: _userAgreementAccepted,
          title: '我已阅读并同意《用户协议》',
          documentId: 'user_agreement',
          onChanged: (value) => setState(() => _userAgreementAccepted = value),
        ),
        _buildConsentItem(
          context,
          checkboxKey: const ValueKey('registration-privacy-policy'),
          value: _privacyPolicyAccepted,
          title: '我已阅读并同意《隐私政策》',
          documentId: 'privacy_policy',
          onChanged: (value) => setState(() => _privacyPolicyAccepted = value),
        ),
        if (!_isEmailRegister) ...[
          const SizedBox(height: 4),
          _buildConsentItem(
            context,
            checkboxKey: const ValueKey('registration-edu-consent'),
            value: _eduDataConsentAccepted,
            title: '我同意《教务数据专项授权》',
            documentId: 'edu_data_consent',
            onChanged: (value) =>
                setState(() => _eduDataConsentAccepted = value),
            emphasize: true,
          ),
        ],
        const SizedBox(height: 4),
        Text(
          '社区规则在首次发布、评论、私信、集市或组队写操作前单独确认；其他说明可在文档中心随时查看。',
          style: TextStyle(fontSize: 11, height: 1.4, color: subText),
        ),
      ],
    );
  }

  Widget _buildConsentItem(
    BuildContext context, {
    required Key checkboxKey,
    required bool value,
    required String title,
    required String documentId,
    required ValueChanged<bool> onChanged,
    bool emphasize = false,
  }) {
    final color = emphasize ? Theme.of(context).colorScheme.primary : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Checkbox(
          key: checkboxKey,
          value: value,
          onChanged: (checked) => onChanged(checked ?? false),
          visualDensity: VisualDensity.compact,
        ),
        Expanded(
          child: TextButton(
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              foregroundColor: color,
            ),
            onPressed: () => LegalDocumentsScreen.open(
              context,
              documentId: documentId,
            ),
            child: Text(title, style: const TextStyle(fontSize: 12.5)),
          ),
        ),
      ],
    );
  }
}
