import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/glass_container.dart';

class AdminCandidatesScreen extends StatefulWidget {
  const AdminCandidatesScreen({super.key});

  @override
  State<AdminCandidatesScreen> createState() => _AdminCandidatesScreenState();
}

class _AdminCandidatesScreenState extends State<AdminCandidatesScreen> {
  List<dynamic> _candidates = [];
  bool _isLoading = false;
  String? _errorMessage;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchCandidates() async {
    final keyword = _searchController.text.trim();
    if (keyword.isEmpty) return;
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    
    try {
      final dio = context.read<AuthProvider>().dio;
      final res = await dio.get(
        '/admin/candidates',
        queryParameters: {'student_id': keyword},
      );
      if (mounted) {
        setState(() {
          _candidates = (res.data as List?) ?? [];
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _inviteAdmin(dynamic candidate) async {
    final dio = context.read<AuthProvider>().dio;
    final messenger = ScaffoldMessenger.of(context);
    final reason = await _showReasonDialog(
      title: '邀请 ${candidate['nickname'] ?? ''} 成为管理员',
      label: '给候选人的邀请理由',
      hint: '例如：社区贡献活跃、处理问题客观，希望邀请你参与管理',
      helperText: '该用户会看到这段文字，并决定是否接受邀请。',
      confirmText: '发送邀请',
    );
    if (!mounted || reason == null) return;

    try {
      await dio.post(
        '/admin/invite/${candidate['id']}',
        data: {'reason': reason},
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('邀请已发送，用户同意后进入管理员代办'),
          backgroundColor: Colors.green,
        ),
      );
      setState(() => _candidates.removeWhere((c) => c['id'] == candidate['id']));
    } on DioException catch (e) {
      if (!mounted) return;
      String msg = '邀请失败';
      if (e.response?.data is Map) {
        msg = (e.response!.data as Map)['error']?.toString() ?? msg;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    }
  }

  Future<String?> _showReasonDialog({
    required String title,
    required String label,
    required String hint,
    required String helperText,
    required String confirmText,
  }) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            helperText: helperText,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final reason = controller.text.trim();
              if (reason.isEmpty) return;
              Navigator.pop(ctx, reason);
            },
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('管理员候选人')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: GlassContainer(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              borderRadius: 12,
              blur: 8,
              opacity: isDark ? 0.1 : 0.4,
              child: TextField(
                controller: _searchController,
                onSubmitted: (_) => _searchCandidates(),
                decoration: InputDecoration(
                  icon: const Icon(Icons.search, color: Colors.grey),
                  hintText: '输入学号或昵称搜索可邀请为管理员的普通用户',
                  hintStyle: const TextStyle(fontSize: 13),
                  border: InputBorder.none,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.arrow_forward, color: Colors.blue),
                    onPressed: _searchCandidates,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _errorMessage != null
                    ? Center(child: Text(_errorMessage!))
                    : _candidates.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                _searchController.text.isEmpty
                                    ? '请输入关键词搜索'
                                    : '未找到候选人',
                                style: TextStyle(color: isDark ? Colors.white54 : Colors.black54),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: _candidates.length,
                            itemBuilder: (context, index) {
                              final candidate = _candidates[index];
                              return Card(
                                margin: const EdgeInsets.only(bottom: 10),
                                color: isDark ? Colors.grey[850] : Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundImage: candidate['avatar_url'] != null
                                        ? NetworkImage(candidate['avatar_url'])
                                        : null,
                                    child: candidate['avatar_url'] == null
                                        ? const Icon(Icons.person)
                                        : null,
                                  ),
                                  title: Text(candidate['nickname'] ?? '未知用户'),
                                  subtitle: Text('学号: ${candidate['student_id'] ?? '未知'}'),
                                  trailing: FilledButton.tonal(
                                    onPressed: () => _inviteAdmin(candidate),
                                    child: const Text('邀请'),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
