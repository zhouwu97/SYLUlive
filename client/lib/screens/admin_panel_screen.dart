import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final Dio _dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  List<dynamic> _reports = [];
  List<dynamic> _candidates = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final authProvider = context.read<AuthProvider>();
    _dio.options.headers['Authorization'] = 'Bearer ${authProvider.token}';

    try {
      final reportsResponse = await _dio.get('/reports');
      final candidatesResponse = await _dio.get('/admin/candidates');

      setState(() {
        _reports = reportsResponse.data;
        _candidates = candidatesResponse.data;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('加载管理数据失败: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('管理员面板'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // 待处理举报
                ExpansionTile(
                  leading: const Icon(Icons.report),
                  title: const Text('举报处理'),
                  subtitle: Text('${_reports.where((r) => r['status'] == 'pending').length} 条待处理'),
                  children: _reports
                      .where((r) => r['status'] == 'pending')
                      .map((report) => _buildReportItem(report))
                      .toList(),
                ),

                // 管理员候选人
                ExpansionTile(
                  leading: const Icon(Icons.person_add),
                  title: const Text('邀请管理员'),
                  subtitle: Text('${_candidates.length} 位候选人'),
                  children: _candidates
                      .map((candidate) => _buildCandidateItem(candidate))
                      .toList(),
                ),

                // 公告管理
                ListTile(
                  leading: const Icon(Icons.campaign),
                  title: const Text('公告管理'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    // TODO: 跳转到公告管理页面
                  },
                ),

                // 超级管理员额外功能
                if (authProvider.user?.isSuperAdmin == true) ...[
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.people),
                    title: const Text('用户管理'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SuperAdminScreen(),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.analytics),
                    title: const Text('系统统计'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      // TODO: 显示系统统计
                    },
                  ),
                ],
              ],
            ),
    );
  }

  Widget _buildReportItem(dynamic report) {
    return ListTile(
      title: Text('举报: ${report['reason']}'),
      subtitle: Text('目标: ${report['target_type']} #${report['target_id']}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.check, color: Colors.green),
            onPressed: () => _handleReport(report['id'], 'handled'),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.red),
            onPressed: () => _handleReport(report['id'], 'ignored'),
          ),
        ],
      ),
    );
  }

  Widget _buildCandidateItem(dynamic candidate) {
    return ListTile(
      leading: CircleAvatar(
        child: Text(candidate['nickname']?.substring(0, 1) ?? '?'),
      ),
      title: Text(candidate['nickname'] ?? '未知'),
      subtitle: Text('诚信度: ${candidate['credit_score']}%'),
      trailing: ElevatedButton(
        onPressed: () => _inviteAdmin(candidate['id']),
        child: const Text('邀请'),
      ),
    );
  }

  Future<void> _handleReport(int reportId, String status) async {
    try {
      await _dio.put('/reports/$reportId/handle', data: {
        'status': status,
      });
      _loadData();
    } catch (e) {
      debugPrint('处理举报失败: $e');
    }
  }

  Future<void> _inviteAdmin(int userId) async {
    try {
      await _dio.post('/admin/invite/$userId');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('邀请已发送')),
        );
      }
    } catch (e) {
      debugPrint('邀请失败: $e');
    }
  }
}

class SuperAdminScreen extends StatelessWidget {
  const SuperAdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('超级管理员面板'),
      ),
      body: const Center(
        child: Text('用户管理页面开发中'),
      ),
    );
  }
}