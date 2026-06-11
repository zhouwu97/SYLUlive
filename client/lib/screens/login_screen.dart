import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/edu_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _studentIdController = TextEditingController();
  final _qqController = TextEditingController();
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

  @override
  void dispose() {
    _studentIdController.dispose();
    _qqController.dispose();
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

  bool get _isGraduateRegister => _isRegister && _registerMode == 'graduate';

  Future<void> _showLoginLimitedDialog(String message) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('登录受限'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _showForgotPasswordDialog();
            },
            child: const Text('去忘记密码'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusManager.instance.primaryFocus?.unfocus();

    final authProvider = context.read<AuthProvider>();
    AuthResult result;

    if (mounted) setState(() => _isLoading = true);

    if (_isRegister) {
      if (_registerMode == 'graduate') {
        result = await authProvider.registerGraduate(
          _qqController.text.trim(),
          _verifyCodeController.text.trim(),
          _appPasswordController.text,
          nickname: _nicknameController.text.trim().isNotEmpty
              ? _nicknameController.text.trim()
              : null,
        );
      } else {
        result = await authProvider.registerWithEdu(
          _studentIdController.text.trim(),
          _appPasswordController.text,
          nickname: _nicknameController.text.trim().isNotEmpty
              ? _nicknameController.text.trim()
              : null,
          eduPassword: _eduPasswordController.text,
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
        if (mounted) setState(() {
          _isRegister = true;
          _eduPasswordController.clear();
          _appPasswordController.clear();
          _nicknameController.clear();
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _eduPasswordFocus.requestFocus();
          }
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.errorMessage!),
          backgroundColor: Colors.red.shade600));
    }
  }

  Future<void> _sendGraduateCode() async {
    final qq = _qqController.text.trim();
    if (qq.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先输入QQ号')),
      );
      return;
    }
    if (mounted) setState(() => _isLoading = true);
    final result = await context.read<AuthProvider>().sendVerifyCode(qq);
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
          content: Text('验证码已发送到 QQ 邮箱'),
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
    final studentIdController =
        TextEditingController(text: _studentIdController.text.trim());
    final eduPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var isSubmitting = false;
    var obscureEduPassword = true;
    var obscureNewPassword = true;
    var obscureConfirmPassword = true;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setLocalState) => AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            title: const Text('忘记密码'),
            content: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '仅已注册软件账号可使用。请用本人教务账号验证身份，验证通过后，下方新密码会替换软件登录密码。',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: studentIdController,
                      maxLength: 10,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '学号',
                        prefixIcon: Icon(Icons.person_outline),
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      validator: (v) {
                        final value = v?.trim() ?? '';
                        if (value.isEmpty) return '请输入学号';
                        if (value.length != 10) return '请输入10位学号';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: eduPasswordController,
                      obscureText: obscureEduPassword,
                      decoration: const InputDecoration(
                        labelText: '教务密码',
                        prefixIcon: Icon(Icons.school_outlined),
                        border: OutlineInputBorder(),
                        helperText: '仅用于确认账号属于本人',
                      ).copyWith(
                        suffixIcon: IconButton(
                          onPressed: () => setLocalState(
                            () => obscureEduPassword = !obscureEduPassword,
                          ),
                          icon: Icon(
                            obscureEduPassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? '请输入教务密码' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: newPasswordController,
                      obscureText: obscureNewPassword,
                      decoration: const InputDecoration(
                        labelText: '新的软件密码',
                        prefixIcon: Icon(Icons.lock_reset),
                        border: OutlineInputBorder(),
                        helperText: '8位以上，需包含数字和字母',
                      ).copyWith(
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
                      decoration: const InputDecoration(
                        labelText: '确认新密码',
                        prefixIcon: Icon(Icons.check_circle_outline),
                        border: OutlineInputBorder(),
                      ).copyWith(
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
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: isSubmitting
                    ? null
                    : () async {
                        if (!formKey.currentState!.validate()) return;
                        setLocalState(() => isSubmitting = true);
                        final authProvider = context.read<AuthProvider>();
                        final result = await authProvider.resetPasswordWithEdu(
                          studentIdController.text.trim(),
                          eduPasswordController.text,
                          newPasswordController.text,
                        );
                        if (!mounted) return;
                        if (result.success) {
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                          if (mounted) setState(() {
                            _isRegister = false;
                            _studentIdController.text =
                                studentIdController.text.trim();
                            _appPasswordController.clear();
                            _eduPasswordController.clear();
                          });
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
                child: isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('确认重置'),
              ),
            ],
          ),
        );
      },
    );

    studentIdController.dispose();
    eduPasswordController.dispose();
    newPasswordController.dispose();
    confirmPasswordController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Card(
                elevation: 8,
                shadowColor: Colors.black26,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                child: Stack(
                  children: [
                    Padding(
                        padding: const EdgeInsets.fromLTRB(28, 40, 28, 28),
                    child: Form(
                      key: _formKey,
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Icon(Icons.school,
                                size: 56,
                                color: Theme.of(context).primaryColor),
                            const SizedBox(height: 12),
                            Text('沈理校园',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.bold),
                                textAlign: TextAlign.center),
                            const SizedBox(height: 4),
                            Text('校园互助社交平台',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: Colors.grey),
                                textAlign: TextAlign.center),
                            const SizedBox(height: 28),

                            if (_isRegister) ...[
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: _isGraduateRegister
                                      ? const Color(0xFFFDF5E8)
                                      : const Color(0xFFF3F6FF),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: _isGraduateRegister
                                        ? const Color(0xFFFFD8A8)
                                        : const Color(0xFFD6E4FF),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _isGraduateRegister
                                          ? '毕业人员注册说明'
                                          : '在校生注册说明',
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      _isGraduateRegister
                                          ? '毕业人员使用 QQ 号注册，验证码会发送到 QQ 邮箱。为降低交易风险，毕业人员账号不能在集市发布帖子，可在首页转到闲鱼等专业平台。'
                                          : '在校生仅使用学号注册，并通过教务密码验证身份。注册成功后可使用校园全部功能。',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        height: 1.45,
                                        color: Colors.grey[700],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],

                            TextFormField(
                              controller: _isGraduateRegister
                                  ? _qqController
                                  : _studentIdController,
                              maxLength: _isGraduateRegister ? 15 : 20,
                              keyboardType: _isGraduateRegister
                                  ? TextInputType.number
                                  : TextInputType.text,
                              decoration: InputDecoration(
                                labelText: _isRegister
                                    ? (_isGraduateRegister ? 'QQ号' : '学号')
                                    : '学号 / QQ',
                                helperText: _isRegister
                                    ? (_isGraduateRegister
                                        ? '仅毕业人员使用 QQ 注册'
                                        : '仅在校生使用学号注册')
                                    : '在校生用学号登录，毕业人员用 QQ 登录',
                                prefixIcon: const Icon(Icons.person_outline),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                              ),
                              validator: (v) {
                                if (v == null || v.isEmpty) {
                                  if (_isRegister) {
                                    return _isGraduateRegister
                                        ? '请输入QQ号'
                                        : '请输入学号';
                                  }
                                  return '请输入学号或QQ';
                                }
                                return null;
                              },
                            ),

                            if (_isRegister) ...[
                              const SizedBox(height: 16),

                              SegmentedButton<String>(
                                segments: const [
                                  ButtonSegment(
                                    value: 'campus',
                                    label: Text('在校生注册'),
                                    icon: Icon(Icons.school_outlined),
                                  ),
                                  ButtonSegment(
                                    value: 'graduate',
                                    label: Text('毕业人员注册'),
                                    icon: Icon(Icons.mark_email_read_outlined),
                                  ),
                                ],
                                selected: {_registerMode},
                                onSelectionChanged: (value) {
                                  FocusManager.instance.primaryFocus?.unfocus();
                                  if (mounted) setState(() {
                                    _registerMode = value.first;
                                    _appPasswordController.clear();
                                    _eduPasswordController.clear();
                                    _verifyCodeController.clear();
                                  });
                                },
                              ),
                              const SizedBox(height: 16),

                              // 昵称
                              TextFormField(
                                controller: _nicknameController,
                                decoration: InputDecoration(
                                  labelText: '昵称（选填）',
                                  prefixIcon: const Icon(Icons.badge_outlined),
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 14),
                                  helperText: '将显示在帖子和评论中',
                                  helperStyle: TextStyle(color: Colors.orange),
                                ),
                              ),
                              const SizedBox(height: 16),

                              if (_registerMode == 'campus')
                                TextFormField(
                                  controller: _eduPasswordController,
                                  focusNode: _eduPasswordFocus,
                                  obscureText: _obscureEduPassword,
                                  decoration: InputDecoration(
                                    labelText: '教务密码',
                                    prefixIcon: const Icon(Icons.lock_outline),
                                    border: OutlineInputBorder(
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 14),
                                    helperText: '用于验证学号真实性',
                                    helperStyle:
                                        TextStyle(color: Colors.orange),
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
                                        decoration: InputDecoration(
                                          labelText: '验证码',
                                          prefixIcon: const Icon(
                                              Icons.verified_outlined),
                                          border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12)),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 16, vertical: 14),
                                          helperText: '发送到 QQ 邮箱',
                                          helperStyle:
                                              TextStyle(color: Colors.orange),
                                        ),
                                        validator: (v) =>
                                            (v == null || v.trim().length != 6)
                                                ? '请输入6位验证码'
                                                : null,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    SizedBox(
                                      height: 54,
                                      child: FilledButton.tonal(
                                        onPressed:
                                            (_isLoading || _codeCooldown > 0)
                                                ? null
                                                : _sendGraduateCode,
                                        child: Text(_codeCooldown > 0
                                            ? '${_codeCooldown}s'
                                            : '发送验证码'),
                                      ),
                                    ),
                                  ],
                                ),
                            ],

                            const SizedBox(height: 16),

                            // APP密码
                            TextFormField(
                              controller: _appPasswordController,
                              obscureText: _obscureAppPassword,
                              decoration: InputDecoration(
                                labelText: _isRegister ? 'APP密码' : '密码',
                                prefixIcon: const Icon(Icons.lock_outline),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                                helperText:
                                    _isRegister ? '8位以上，需包含数字和字母' : null,
                                helperStyle: TextStyle(color: Colors.orange),
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

                            if (!_isRegister)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: _isLoading
                                      ? null
                                      : _showForgotPasswordDialog,
                                  child: Text(
                                    '忘记密码？',
                                    style: TextStyle(
                                        color: Theme.of(context).primaryColor),
                                  ),
                                ),
                              ),

                            const SizedBox(height: 24),

                            // 提交按钮
                            Consumer<AuthProvider>(
                              builder: (context, auth, child) => SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  onPressed: _isLoading ? null : _submit,
                                  style: ElevatedButton.styleFrom(
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(12))),
                                  child: _isLoading
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white))
                                      : Text(_isRegister ? '注册' : '登录',
                                          style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),

                            // 切换登录/注册
                            TextButton(
                              onPressed: () {
                                FocusManager.instance.primaryFocus?.unfocus();
                                if (mounted) setState(() {
                                  _isRegister = !_isRegister;
                                  _eduPasswordController.clear();
                                  _nicknameController.clear();
                                  _appPasswordController.clear();
                                  _verifyCodeController.clear();
                                });
                              },
                              child: Text(_isRegister ? '已有账号？去登录' : '没有账号？去注册',
                                  style: TextStyle(
                                      color: Theme.of(context).primaryColor)),
                            ),
                          ]),
                    )),
                    Positioned(
                      top: 12,
                      right: 16,
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        style: TextButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text('跳过',
                            style: TextStyle(
                                fontSize: 14,
                                color: isDark ? Colors.white70 : Colors.black54)),
                      ),
                    ),
                  ],
                ),
              )),
        ),
      ),
    );
  }
}
