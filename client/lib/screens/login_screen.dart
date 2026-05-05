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
  final _eduPasswordController = TextEditingController(); // 教务密码
  final _appPasswordController = TextEditingController(); // APP密码
  final _nicknameController = TextEditingController(); // 昵称
  final _formKey = GlobalKey<FormState>();
  final _eduPasswordFocus = FocusNode();

  bool _isRegister = false;
  bool _isLoading = false;

  @override
  void dispose() {
    _studentIdController.dispose();
    _eduPasswordController.dispose();
    _appPasswordController.dispose();
    _nicknameController.dispose();
    _eduPasswordFocus.dispose();
    super.dispose();
  }

  String? _validateAppPassword(String? v) {
    if (v == null || v.isEmpty) return '请输入密码';
    if (v.length < 8) return '密码至少8个字符';
    if (!RegExp(r'[0-9]').hasMatch(v)) return '密码需包含数字';
    if (!RegExp(r'[a-zA-Z]').hasMatch(v)) return '密码需包含字母';
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final authProvider = context.read<AuthProvider>();
    AuthResult result;

    setState(() => _isLoading = true);

    if (_isRegister) {
      // 注册：教务验证后自动注册
      result = await authProvider.registerWithEdu(
        _studentIdController.text.trim(),
        _appPasswordController.text,
        nickname: _nicknameController.text.trim().isNotEmpty
            ? _nicknameController.text.trim()
            : null,
        eduPassword: _eduPasswordController.text,
      );
    } else {
      // 登录：学号 + APP密码
      result = await authProvider.login(
          _studentIdController.text.trim(), _appPasswordController.text);
    }

    setState(() => _isLoading = false);

    if (result.success && mounted) {
      // 先设置 Authorization header，再刷新 EduProvider
      if (authProvider.token != null) {
        authProvider.dio.options.headers['Authorization'] =
            'Bearer ${authProvider.token}';
        context.read<EduProvider>().setUserId(authProvider.user!.id.toString());
      }
      Navigator.pop(context);
    } else if (mounted && result.errorMessage != null) {
      if (!_isRegister && result.errorMessage!.contains('尚未注册')) {
        setState(() {
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

  Future<void> _showForgotPasswordDialog() async {
    final studentIdController =
        TextEditingController(text: _studentIdController.text.trim());
    final eduPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var isSubmitting = false;

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
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '教务密码',
                        prefixIcon: Icon(Icons.school_outlined),
                        border: OutlineInputBorder(),
                        helperText: '仅用于确认账号属于本人',
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? '请输入教务密码' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: newPasswordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '新的软件密码',
                        prefixIcon: Icon(Icons.lock_reset),
                        border: OutlineInputBorder(),
                        helperText: '8位以上，需包含数字和字母',
                      ),
                      validator: _validateAppPassword,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: confirmPasswordController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '确认新密码',
                        prefixIcon: Icon(Icons.check_circle_outline),
                        border: OutlineInputBorder(),
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
                          setState(() {
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
      body: Stack(children: [
        Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 16,
            child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('跳过',
                    style: TextStyle(
                        color: isDark ? Colors.white70 : Colors.black54)))),
        Center(
            child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Card(
                elevation: 8,
                shadowColor: Colors.black26,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                child: Padding(
                    padding: const EdgeInsets.all(28),
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

                            // 学号
                            TextFormField(
                              controller: _studentIdController,
                              maxLength: 20,
                              decoration: InputDecoration(
                                labelText: '学号',
                                prefixIcon: const Icon(Icons.person_outline),
                                border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 14),
                              ),
                              validator: (v) =>
                                  (v == null || v.isEmpty) ? '请输入学号' : null,
                            ),

                            if (_isRegister) ...[
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

                              // 教务密码
                              TextFormField(
                                controller: _eduPasswordController,
                                focusNode: _eduPasswordFocus,
                                obscureText: true,
                                decoration: InputDecoration(
                                  labelText: '教务密码',
                                  prefixIcon: const Icon(Icons.lock_outline),
                                  border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 14),
                                  helperText: '用于验证学号真实性',
                                  helperStyle: TextStyle(color: Colors.orange),
                                ),
                                validator: (v) =>
                                    (v == null || v.isEmpty) ? '请输入教务密码' : null,
                              ),
                            ],

                            const SizedBox(height: 16),

                            // APP密码
                            TextFormField(
                              controller: _appPasswordController,
                              obscureText: true,
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
                                setState(() {
                                  _isRegister = !_isRegister;
                                  _eduPasswordController.clear();
                                  _nicknameController.clear();
                                  _appPasswordController.clear();
                                });
                              },
                              child: Text(_isRegister ? '已有账号？去登录' : '没有账号？去注册',
                                  style: TextStyle(
                                      color: Theme.of(context).primaryColor)),
                            ),
                          ]),
                    )),
              )),
        )),
      ]),
    );
  }
}
