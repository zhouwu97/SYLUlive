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
  final _eduPasswordController = TextEditingController(); // 教务密码
  final _passwordController = TextEditingController();     // APP密码
  final _confirmPasswordController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isRegister = false;
  bool _isEduVerified = false;  // 教务是否验证通过
  bool _isEduVerifying = false; // 验证中
  bool _isSubmitting = false;

  @override
  void dispose() {
    _studentIdController.dispose();
    _eduPasswordController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _verifyEdu() async {
    if (!_formKey.currentState!.validate()) return;
    
    final studentId = _studentIdController.text.trim();
    final eduPassword = _eduPasswordController.text;

    // 先验证学号格式
    if (studentId.length != 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入10位学号'), backgroundColor: Colors.red));
      return;
    }

    setState(() => _isEduVerifying = true);

    try {
      // 调用教务验证接口
      final result = await context.read<AuthProvider>().verifyEdu(studentId, eduPassword);
      
      setState(() => _isEduVerifying = false);

      if (result.success) {
        setState(() => _isEduVerified = true);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('教务验证通过，请设置昵称和APP密码'), backgroundColor: Colors.green));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.errorMessage ?? '教务验证失败'), backgroundColor: Colors.red));
        }
      }
    } catch (e) {
      setState(() => _isEduVerifying = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('验证失败: $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    // 注册模式需要先验证教务
    if (_isRegister && !_isEduVerified) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先验证教务账号'), backgroundColor: Colors.red));
      return;
    }

    final authProvider = context.read<AuthProvider>();
    AuthResult result;

    setState(() => _isSubmitting = true);

    if (_isRegister) {
      // 教务验证后注册
      result = await authProvider.registerWithEdu(
        _studentIdController.text,
        _passwordController.text,
        nickname: _nicknameController.text,
        eduPassword: _eduPasswordController.text,
      );
    } else {
      // 普通登录
      result = await authProvider.login(_studentIdController.text, _passwordController.text);
    }

    setState(() => _isSubmitting = false);

    if (result.success && mounted) {
      Navigator.pop(context);
    } else if (mounted && result.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.errorMessage!), backgroundColor: Colors.red.shade600));
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

                // 学号
                TextFormField(
                  controller: _studentIdController,
                  maxLength: 10,
                  enabled: !_isEduVerified,  // 验证通过后不可修改
                  decoration: InputDecoration(
                    labelText: '学号',
                    prefixIcon: const Icon(Icons.person_outline),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    helperText: _isRegister ? '注册后学号不可更改' : null,
                    helperStyle: TextStyle(color: Colors.orange),
                  ),
                  validator: (v) => (v == null || v.isEmpty) ? '请输入学号' : (v.length != 10 ? '请输入10位学号' : null),
                ),

                if (_isRegister) ...[
                  const SizedBox(height: 16),

                  // 教务密码（注册时必须验证）
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _eduPasswordController,
                        enabled: !_isEduVerified,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: '教务密码',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          helperText: _isEduVerified ? '已验证' : '用于验证学号真实性',
                          helperStyle: TextStyle(color: _isEduVerified ? Colors.green : Colors.orange),
                        ),
                        validator: (v) => (v == null || v.isEmpty) ? '请输入教务密码' : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: (_isEduVerifying || _isEduVerified) ? null : _verifyEdu,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        backgroundColor: _isEduVerified ? Colors.green : null,
                      ),
                      child: _isEduVerifying 
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_isEduVerified ? '已验证' : '验证', style: const TextStyle(fontSize: 13)),
                    ),
                  ]),
                ],

                const SizedBox(height: 16),

                // APP密码
                TextFormField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: _isRegister ? 'APP密码' : '密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    helperText: _isRegister ? '此密码用于APP登录，与教务密码不同' : null,
                    helperStyle: TextStyle(color: Colors.orange),
                  ),
                  validator: (v) => (v == null || v.isEmpty) ? '请输入密码' : (_isRegister && v.length < 8 ? '密码至少8个字符' : null),
                ),

                // 注册时显示昵称和确认密码
                if (_isRegister && _isEduVerified) ...[
                  const SizedBox(height: 16),

                  // 确认密码
                  TextFormField(
                    controller: _confirmPasswordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: '确认密码',
                      prefixIcon: const Icon(Icons.lock_outline),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                    validator: (v) => (v == null || v.isEmpty) 
                        ? '请输入确认密码' 
                        : (v != _passwordController.text ? '两次密码不一致' : null),
                  ),

                  const SizedBox(height: 16),

                  // 昵称
                  TextFormField(
                    controller: _nicknameController,
                    maxLength: 12,
                    decoration: InputDecoration(
                      labelText: '昵称',
                      prefixIcon: const Icon(Icons.badge_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty) ? '请输入昵称' : null,
                  ),
                ],

                const SizedBox(height: 24),

                // 提交按钮
                Consumer<AuthProvider>(
                  builder: (context, auth, child) => SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: (_isSubmitting || (_isRegister && !_isEduVerified)) ? null : _submit,
                      style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      child: _isSubmitting
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(_isRegister ? '注册' : '登录', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 切换登录/注册
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isRegister = !_isRegister;
                      _isEduVerified = false;
                      _isEduVerifying = false;
                      _eduPasswordController.clear();
                      _passwordController.clear();
                      _confirmPasswordController.clear();
                      _nicknameController.clear();
                    });
                  },
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