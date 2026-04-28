import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class SuperAdminScreen extends StatefulWidget {
  const SuperAdminScreen({super.key});

  @override
  State<SuperAdminScreen> createState() => _SuperAdminScreenState();
}

class _SuperAdminScreenState extends State<SuperAdminScreen> {
  final Dio _dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  List<dynamic> _users = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    final authProvider = context.read<AuthProvider>();
    _dio.options.headers['Authorization'] = 'Bearer ${authProvider.token}';
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    try {
      final response = await _dio.get('/super/users', queryParameters: {
        if (_searchQuery.isNotEmpty) 'search': _searchQuery,
      });

      setState(() {
        _users = response.data;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('加载用户失败: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('用户管理'),
      ),
      body: Column(
        children: [
          // 搜索栏
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: '搜索学号/昵称...',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                _searchQuery = value;
                _loadUsers();
              },
            ),
          ),

          // 用户列表
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _users.isEmpty
                    ? const Center(child: Text('暂无用户'))
                    : ListView.builder(
                        itemCount: _users.length,
                        itemBuilder: (context, index) {
                          final user = _users[index];
                          return _buildUserItem(user);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserItem(dynamic user) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundImage: user['avatar']?.toString().isNotEmpty == true
              ? NetworkImage(user['avatar'])
              : null,
          child: user['avatar']?.toString().isEmpty == true
              ? Text(user['nickname']?.toString().substring(0, 1) ?? '?')
              : null,
        ),
        title: Text(user['nickname'] ?? '未知'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('学号: ${user['student_id']}'),
            Text('角色: ${user['role']} | 诚信度: ${user['credit_score']}%'),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'role') {
              _showChangeRoleDialog(user);
            } else if (value == 'reset') {
              _resetPassword(user['id']);
            } else if (value == 'delete') {
              _deleteUser(user['id']);
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'role', child: Text('修改角色')),
            const PopupMenuItem(value: 'reset', child: Text('重置密码')),
            if (user['role'] != 'super_admin')
              const PopupMenuItem(value: 'delete', child: Text('删除用户')),
          ],
        ),
      ),
    );
  }

  void _showChangeRoleDialog(dynamic user) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修改角色'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('用户: ${user['nickname']}'),
            const SizedBox(height: 16),
            if (user['role'] != 'super_admin') ...[
              ListTile(
                title: const Text('设为普通用户'),
                onTap: () => _changeRole(user['id'], 'user'),
              ),
              ListTile(
                title: const Text('设为管理员'),
                onTap: () => _changeRole(user['id'], 'admin'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _changeRole(int userId, String role) async {
    try {
      await _dio.put('/super/users/$userId/role', data: {'role': role});
      if (mounted) {
        Navigator.pop(context);
        _loadUsers();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('角色修改成功')),
        );
      }
    } catch (e) {
      debugPrint('修改角色失败: $e');
    }
  }

  Future<void> _resetPassword(int userId) async {
    try {
      final response = await _dio.post('/super/users/$userId/reset_password');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('密码已重置为: ${response.data['message']}')),
        );
      }
    } catch (e) {
      debugPrint('重置密码失败: $e');
    }
  }

  Future<void> _deleteUser(int userId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('确定要删除此用户吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _dio.delete('/super/users/$userId');
        _loadUsers();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('用户已删除')),
          );
        }
      } catch (e) {
        debugPrint('删除用户失败: $e');
      }
    }
  }
}