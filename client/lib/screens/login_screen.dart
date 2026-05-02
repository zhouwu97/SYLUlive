import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _studentIdController = TextEditingController();
  final _passwordController = TextEditingController();
  final _qqController = TextEditingController();
  final _codeController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isRegister = false;
  bool _codeSent = false;
  bool _codeVerified = false;
  bool _sending = false;

  @override
  void dispose() {
    _studentIdController.dispose();
    _passwordController.dispose();
    _qqController.dispose();
    _codeController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final qq = _qqController.text.trim();
    if (qq.length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入正确的QQ号')));
      return;
    }
    setState(() => _sending = true);
    final result = await context.read<AuthProvider>().sendVerifyCode(qq);
    setState(() {
      _sending = false;
      _codeSent = result.success;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? '验证码已发送到 $qq@qq.com' : (result.errorMessage ?? '发送失败'))));
    }
  }

  Future<void> _verifyCode() async {
    final qq = _qqController.text.trim();
    final code = _codeController.text.trim();
    if (qq.isEmpty || code.isEmpty) return;
    final result = await context.read<AuthProvider>().verifyCode(qq, code);
    setState(() => _codeVerified = result.success);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.success ? '验证通过' : (result.errorMessage ?? '验证码错误'))));
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_isRegister && !_codeVerified) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先验证QQ号')));
      return;
    }

    final authProvider = context.read<AuthProvider>();
    AuthResult result;

    if (_isRegister) {
      result = await authProvider.register(
        _studentIdController.text,
        _passwordController.text,
        nickname: _nicknameController.text,
        qq: _qqController.text,
      );
    } else {
      result = await authProvider.login(_studentIdController.text, _passwordController.text);
    }

    if (result.success && mounted) {
      Navigator.pop(context);
    } else if (mounted && result.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.errorMessage!), backgroundColor: Colors.red.shade600));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: [
        Positioned(
          top: MediaQuery.of(context).padding.top + 8, right: 16,
          child: TextButton(onPressed: () => Navigator.pop(context), child: Text('跳过', style: TextStyle(color: isDark ? Colors.white70 : Colors.black54)))),
        Center(child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400), child: Card(
            elevation: 8, shadowColor: Colors.black26, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(padding: const EdgeInsets.all(28), child: Form(key: _formKey,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Icon(Icons.school, size: 56, color: Theme.of(context).primaryColor),
                const SizedBox(height: 12),
                Text('沈理校园', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 4),
                Text('校园互助社交平台', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey), textAlign: TextAlign.center),
                const SizedBox(height: 28),

                // 手机号
                TextFormField(
                  controller: _studentIdController, keyboardType: TextInputType.phone, maxLength: 11,
                  decoration: InputDecoration(labelText: '手机号', prefixIcon: const Icon(Icons.phone_android_outlined), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
                  validator: (v) => (v == null || v.isEmpty) ? '请输入手机号' : (v.length != 11 || !RegExp(r'^1[3-9]\d{9}$').hasMatch(v) ? '请输入正确的11位手机号' : null),
                ),
                const SizedBox(height: 16),

                // 密码
                TextFormField(
                  controller: _passwordController, obscureText: true,
                  decoration: InputDecoration(labelText: '密码', prefixIcon: const Icon(Icons.lock_outline), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
                  validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : (_isRegister && v.length < 8 ? '密码至少8个字符' : null),
                ),
                const SizedBox(height: 16),

                // 注册时显示 QQ 验证 + 昵称
                if (_isRegister) ...[
                  // QQ 号
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _qqController, keyboardType: TextInputType.number, maxLength: 15,
                        decoration: InputDecoration(labelText: 'QQ号', prefixIcon: const Icon(Icons.email_outlined), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), counterText: ''),
                        validator: (v) => (v == null || v.length < 5) ? '请输入正确的QQ号' : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _sending ? null : _sendCode,
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14)),
                      child: Text(_sending ? '发送中' : _codeSent ? '重发' : '发送验证码', style: const TextStyle(fontSize: 13)),
                    ),
                  ]),
                  const SizedBox(height: 12),

                  // 验证码
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _codeController, keyboardType: TextInputType.number, maxLength: 6,
                        decoration: InputDecoration(labelText: '验证码', prefixIcon: const Icon(Icons.pin_outlined), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14), counterText: ''),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _codeVerified ? null : _verifyCode,
                      style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14), backgroundColor: _codeVerified ? Colors.green : null),
                      child: Text(_codeVerified ? '已验证' : '验证', style: const TextStyle(fontSize: 13)),
                    ),
                  ]),
                  const SizedBox(height: 12),

                  // 昵称
                  TextFormField(
                    controller: _nicknameController, maxLength: 12,
                    decoration: InputDecoration(labelText: '昵称（选填）', prefixIcon: const Icon(Icons.badge_outlined), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
                    validator: (_) => null,
                  ),
                ],

                const SizedBox(height: 24),

                // 提交按钮
                Consumer<AuthProvider>(
                  builder: (context, auth, child) => SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: auth.isLoading ? null : _submit,
                      style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: auth.isLoading
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(_isRegister ? '注册' : '登录', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 切换登录/注册
                TextButton(
                  onPressed: () => setState(() { _isRegister = !_isRegister; _codeSent = false; _codeVerified = false; }),
                  child: Text(_isRegister ? '已有账号？去登录' : '没有账号？去注册', style: TextStyle(color: Theme.of(context).primaryColor)),
                ),
              ]),
            )),
          )),
        )),
      ]),
    );
  }
}
