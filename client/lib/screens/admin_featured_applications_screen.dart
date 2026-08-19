import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'post_detail_screen.dart';

class AdminFeaturedApplicationsScreen extends StatefulWidget {
  const AdminFeaturedApplicationsScreen({super.key});

  @override
  State<AdminFeaturedApplicationsScreen> createState() =>
      _AdminFeaturedApplicationsScreenState();
}

class _AdminFeaturedApplicationsScreenState
    extends State<AdminFeaturedApplicationsScreen> {
  List<dynamic> _featuredApplications = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final response = await dio.get('/admin/featured-applications');
      if (!mounted) return;
      setState(() {
        _featuredApplications = (response.data as List?) ?? [];
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '加载精华申请失败';
      });
    }
  }

  Future<void> _approveFeatured(dynamic id) async {
    final reason = await _askAdminReason('通过精华申请', '审核理由');
    if (reason == null) return;
    try {
      await context.read<AuthProvider>().dio.post(
        '/admin/featured-applications/$id/approve',
        data: {'reason': reason},
      );
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _rejectFeatured(dynamic id, bool malicious) async {
    int penaltyPoints = 0;
    String? reason;
    if (malicious) {
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) {
          final controller = TextEditingController();
          int points = 5;
          return StatefulBuilder(builder: (context, setState) {
            return AlertDialog(
              title: const Text('恶意驳回并扣分'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(hintText: '说明恶意/低质量原因'),
                  ),
                  const SizedBox(height: 16),
                  const Text('选择扣除诚信分：'),
                  DropdownButton<int>(
                    value: points,
                    isExpanded: true,
                    items: [0, 2, 5, 10]
                        .map((e) =>
                            DropdownMenuItem(value: e, child: Text('$e分')))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => points = val);
                    },
                  ),
                  const SizedBox(height: 16),
                  const Text('恶意申请会扣除用户诚信分，确认继续？',
                      style: TextStyle(color: Colors.red, fontSize: 13)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(
                      ctx, {'reason': controller.text, 'points': points}),
                  child: const Text('确认驳回'),
                ),
              ],
            );
          });
        },
      );
      if (result == null) return;
      reason = result['reason'];
      penaltyPoints = result['points'];
    } else {
      reason = await _askAdminReason('驳回精华申请', '审核理由');
      if (reason == null) return;
    }

    try {
      await context.read<AuthProvider>().dio.post(
        '/admin/featured-applications/$id/reject',
        data: {
          'reason': reason,
          'is_malicious': malicious,
          'penalty_points': penaltyPoints,
        },
      );
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<String?> _askAdminReason(String title, String hint) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('精华申请')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!))
              : _buildFeaturedApplicationsContent(),
    );
  }

  Widget _buildFeaturedApplicationsContent() {
    if (_featuredApplications.isEmpty) {
      return const Center(child: Text('暂无精华申请'));
    }
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.all(16),
        itemCount: _featuredApplications.length,
        itemBuilder: (context, index) {
          final item =
              Map<String, dynamic>.from(_featuredApplications[index] as Map);
          final post = item['post'] as Map?;
          final applicant = item['applicant'] as Map?;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    post?['title']?.toString().isNotEmpty == true
                        ? post!['title'].toString()
                        : '帖子 #${item['post_id']}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (post?['content']?.toString().isNotEmpty == true) ...[
                    const SizedBox(height: 4),
                    Text(
                      post!['content'].toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text('作者：${post?['author']?['nickname'] ?? '未知'}'),
                  Text(
                      '申请人：${applicant?['nickname'] ?? item['applicant_id']} (诚信分: ${applicant?['credit_score'] ?? '-'})'),
                  Text('理由：${item['reason'] ?? ''}'),
                  Text('状态：${item['status'] ?? ''}'),
                  Text(
                    '来源：${item['source'] == 'moderator' ? '版主推荐' : '用户申请'}'
                    '${item['section_id'] != null ? ' · 来自版块 #${item['section_id']}' : ''}',
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  PostDetailScreen(postId: item['post_id']),
                            ),
                          );
                        },
                        child: const Text('查看原帖'),
                      ),
                      if (item['status'] == 'pending') ...[
                        OutlinedButton(
                          onPressed: () => _rejectFeatured(item['id'], false),
                          child: const Text('普通驳回'),
                        ),
                        OutlinedButton(
                          onPressed: () => _rejectFeatured(item['id'], true),
                          child: const Text('恶意驳回'),
                        ),
                        FilledButton(
                          onPressed: () => _approveFeatured(item['id']),
                          child: const Text('通过'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
