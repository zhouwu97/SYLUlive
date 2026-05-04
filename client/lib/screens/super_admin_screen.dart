import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class SuperAdminScreen extends StatefulWidget {
  const SuperAdminScreen({super.key});
  @override
  State<SuperAdminScreen> createState() => _SuperAdminScreenState();
}

class _SuperAdminScreenState extends State<SuperAdminScreen> with SingleTickerProviderStateMixin {
  late Dio _dio;
  late TabController _tabController;
  List<dynamic> _users = [];
  List<dynamic> _pendingInvitations = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    final authProvider = context.read<AuthProvider>();
    _dio.options.headers['Authorization'] = 'Bearer ${authProvider.token}';
    _loadAll();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);
    await Future.wait([_loadUsers(), _loadInvitations()]);
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadUsers() async {
    try {
      final res = await _dio.get('/super/users', queryParameters: {
        if (_searchQuery.isNotEmpty) 'search': _searchQuery,
      });
      _users = res.data as List;
    } catch (_) {}
  }

  Future<void> _loadInvitations() async {
    try {
      final res = await _dio.get('/super/invitations/pending');
      _pendingInvitations = res.data as List;
    } catch (_) {}
  }

  Future<void> _approveInvitation(dynamic inv, bool approve) async {
    String? rejectReason;
    if (!approve) {
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('驳回理由（选填）'),
          content: TextField(controller: ctrl, maxLines: 2, decoration: const InputDecoration(hintText: '可选填驳回原因')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('驳回')),
          ],
        ),
      );
      if (ok != true) return;
      rejectReason = ctrl.text.trim();
    }

    try {
      if (approve) {
        await _dio.post('/super/invitations/${inv['id']}/approve');
      } else {
        await _dio.post('/super/invitations/${inv['id']}/approve', data: {'reject': true, 'reason': rejectReason});
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(approve ? '已批准' : '已驳回'), backgroundColor: approve ? Colors.green : Colors.red),
        );
        _loadInvitations();
      }
    } catch (e) {
      debugPrint('操作失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('超级管理员面板'),
        leading: const BackButton(),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '用户管理'),
            Tab(text: '管理员审批'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildUsersTab(),
          _buildApprovalsTab(),
        ],
      ),
    );
  }

  Widget _buildUsersTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          decoration: const InputDecoration(hintText: '搜索学号/昵称...', prefixIcon: Icon(Icons.search), border: OutlineInputBorder()),
          onChanged: (v) { _searchQuery = v; _loadUsers(); },
        ),
      ),
      Expanded(
        child: _users.isEmpty
            ? const Center(child: Text('暂无用户'))
            : ListView.builder(
                itemCount: _users.length,
                itemBuilder: (_, i) => _buildUserItem(_users[i]),
              ),
      ),
    ]);
  }

  Widget _buildUserItem(dynamic user) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(child: Text((user['nickname'] ?? '?').toString().substring(0, 1))),
        title: Text(user['nickname'] ?? '未知'),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('学号: ${user['student_id']}'),
          Text('角色: ${user['role']} | 诚信: ${user['credit_score']}%'),
        ]),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _handleUserAction(user, v),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'role', child: Text('修改角色')),
            const PopupMenuItem(value: 'reset', child: Text('重置密码')),
            if (user['role'] != 'super_admin') const PopupMenuItem(value: 'delete', child: Text('删除用户')),
          ],
        ),
      ),
    );
  }

  void _handleUserAction(dynamic user, String action) {
    if (action == 'role') _showChangeRoleDialog(user);
    else if (action == 'reset') _resetPassword(user['id']);
    else if (action == 'delete') _deleteUser(user['id']);
  }

  Widget _buildApprovalsTab() {
    if (_pendingInvitations.isEmpty) return const Center(child: Text('暂无待审批的申请'));
    return RefreshIndicator(
      onRefresh: _loadAll,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _pendingInvitations.length,
        itemBuilder: (_, i) {
          final inv = _pendingInvitations[i];
          final user = inv['user'] ?? {};
          final inviter = inv['inviter'] ?? {};
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  CircleAvatar(radius: 18, child: Text((user['nickname'] ?? '?').toString().substring(0, 1))),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(user['nickname'] ?? '未知', style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('学号: ${user['student_id']} | 诚信: ${user['credit_score']}%', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    Text('邀请人: ${inviter['nickname'] ?? '未知'}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ])),
                ]),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  TextButton.icon(
                    onPressed: () => _approveInvitation(inv, false),
                    icon: const Icon(Icons.close, size: 16, color: Colors.red),
                    label: const Text('驳回', style: TextStyle(color: Colors.red)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () => _approveInvitation(inv, true),
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('批准'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  ),
                ]),
              ]),
            ),
          );
        },
      ),
    );
  }

  // --- 以下为原有用户管理逻辑 ---
  void _showChangeRoleDialog(dynamic user) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改角色'),
        content: Text('用户: ${user['nickname']}'),
        actions: [
          if (user['role'] != 'super_admin')
            TextButton(onPressed: () { _changeRole(user['id'], 'user'); Navigator.pop(ctx); }, child: const Text('普通用户')),
          TextButton(onPressed: () { _changeRole(user['id'], 'admin'); Navigator.pop(ctx); }, child: const Text('管理员')),
        ],
      ),
    );
  }

  Future<void> _changeRole(int uid, String role) async {
    try {
      await _dio.put('/super/users/$uid/role', data: {'role': role});
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('角色修改成功'))); _loadUsers(); }
    } catch (_) {}
  }

  Future<void> _resetPassword(int uid) async {
    try {
      await _dio.post('/super/users/$uid/reset_password');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('密码已重置')));
    } catch (_) {}
  }

  Future<void> _deleteUser(int uid) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('确认删除'), content: const Text('不可撤销'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('删除')),
      ],
    ));
    if (ok == true) {
      try { await _dio.delete('/super/users/$uid'); _loadUsers(); } catch (_) {}
    }
  }
}
