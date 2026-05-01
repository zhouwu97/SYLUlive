import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart' show getSharedDio;
import '../models/exam_question.dart';
import '../providers/auth_provider.dart';
import 'exam_preview_screen.dart';

/// 题库提取页面 - 填写学号密码，调用服务器 Rod API
class ExamExtractScreen extends StatefulWidget {
  const ExamExtractScreen({super.key});

  @override
  State<ExamExtractScreen> createState() => _ExamExtractScreenState();
}

class _ExamExtractScreenState extends State<ExamExtractScreen> {
  final _urlController = TextEditingController(text: 'https://www.cctrcloud.net/practice/rzykIndex.html');
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _status;

  static const _schoolCode = 'U101441';

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthProvider>();
    _usernameController.text = auth.user?.studentId ?? '';
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _startExtract() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写学号和密码')),
      );
      return;
    }

    setState(() {
      _loading = true;
      _status = '正在连接服务器...';
    });

    try {
      final dio = getSharedDio();
      final response = await dio.post(
        '/exam/extract',
        data: {
          'url': _urlController.text.trim(),
          'username': username,
          'password': password,
        },
      );

      if (!mounted) return;

      if (response.statusCode == 200 && response.data['success'] == true) {
        final list = response.data['questions'] as List<dynamic>;
        final questions = list
            .map((e) => ExamQuestion.fromJson(e as Map<String, dynamic>))
            .toList();

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ExamPreviewScreen(questions: questions),
          ),
        );
      } else {
        final error = response.data['error'] ?? '未知错误';
        setState(() {
          _status = '提取失败: $error';
          _loading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('提取失败: $error'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().length > 80 ? e.toString().substring(0, 80) + '...' : e.toString();
      setState(() {
        _status = '请求失败: $msg';
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请求失败: $msg'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1A1A2E) : Colors.grey[100],
      appBar: AppBar(
        title: const Text('题库提取'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 图标
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.auto_stories, color: Colors.white, size: 40),
              ),
              const SizedBox(height: 24),
              Text(
                '融智云考题库提取',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '填写练习页面地址和账号密码，服务器自动提取',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white60 : Colors.grey[600],
                ),
              ),
              const SizedBox(height: 32),

              // URL 输入
              _buildField(
                controller: _urlController,
                label: '练习页面地址',
                icon: Icons.link,
                isDark: isDark,
              ),
              const SizedBox(height: 16),

              // 学号输入
              _buildField(
                controller: _usernameController,
                label: '学号',
                icon: Icons.person,
                isDark: isDark,
              ),
              const SizedBox(height: 16),

              // 密码输入
              _buildField(
                controller: _passwordController,
                label: '密码',
                icon: Icons.lock,
                isDark: isDark,
                obscure: true,
              ),
              const SizedBox(height: 24),

              // 提取按钮
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _loading ? null : _startExtract,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF667EEA),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: _loading
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(_status ?? '处理中...', style: const TextStyle(fontSize: 14)),
                          ],
                        )
                      : const Text('开始提取', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),

              if (_status != null && !_loading)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _status!,
                    style: TextStyle(color: isDark ? Colors.white60 : Colors.grey[600], fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required bool isDark,
    bool obscure = false,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: TextStyle(fontSize: 15, color: isDark ? Colors.white : Colors.black87),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        filled: true,
        fillColor: isDark ? Colors.white10 : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}
