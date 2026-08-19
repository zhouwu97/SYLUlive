import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
import '../utils/app_feedback.dart';

class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen> {
  List<dynamic> _reports = [];
  bool _reportsForbidden = false;
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
      final response = await dio.get('/reports');
      if (!mounted) return;
      setState(() {
        _reports = (response.data as List?) ?? [];
        _reportsForbidden = false;
        _isLoading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        if (e.response?.statusCode == 403) {
          _reportsForbidden = true;
        } else {
          _errorMessage = AppFeedback.dioErrorMessage(e, fallback: '加载失败');
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _handleReport(dynamic report) async {
    final deleteReasonController = TextEditingController();
    final resultController = TextEditingController();

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: Row(
            children: [
              const Icon(Icons.gavel, color: Colors.orange, size: 24),
              const SizedBox(width: 8),
              const Text('处理举报'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GlassContainer(
                  padding: const EdgeInsets.all(12),
                  borderRadius: 12,
                  blur: 0,
                  opacity: isDark ? 0.1 : 0.05,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '目标: ${report['target_type'] == 'reply' ? '评论' : '帖子'} #${report['target_id']}',
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark ? Colors.white60 : Colors.grey[600],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '原因: ${report['reason'] ?? '未知'}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: resultController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: '处理结果（必填，不会删除内容）',
                    hintText: '例如：举报不成立；已警告发布者；内容无需处理',
                    helperText: '用于管理员处理记录，用户内容会保留。',
                    helperMaxLines: 2,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: deleteReasonController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: '删除理由（选填，填写后将删除内容）',
                    hintText: '例如：包含辱骂、人身攻击或违规联系方式',
                    helperText: '留空表示不删除；填写后内容会被软删除，发布者申诉时可看到。',
                    helperMaxLines: 3,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'ignored'),
              child: const Text('忽略', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, 'handled'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('确认处理'),
            ),
          ],
        );
      },
    );

    if (action == null) return;

    try {
      final dio = context.read<AuthProvider>().dio;
      await dio.put(
        '/reports/${report['id']}/handle',
        data: {
          'status': action,
          'result': resultController.text,
          'delete_reason': deleteReasonController.text,
        },
      );
      if (mounted) {
        final deleted = action == 'handled' &&
            deleteReasonController.text.trim().isNotEmpty;
        final message = deleted
            ? '已处理并删除相关内容'
            : (action == 'handled' ? '举报已处理' : '已忽略');
        setState(() => _reports.removeWhere((r) => r['id'] == report['id']));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: action == 'handled' ? Colors.green : Colors.grey,
          ),
        );
      }
    } on DioException catch (e) {
      String msg = '操作失败';
      if (e.response?.data is Map) {
        msg = (e.response!.data as Map)['error']?.toString() ?? msg;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(title: const Text('举报处理')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(child: Text(_errorMessage!))
              : _buildReportsContent(isDark),
    );
  }

  Widget _buildReportsContent(bool isDark) {
    if (_reportsForbidden) {
      return Center(
        child: Text('当前账号暂无举报处理权限',
            style: TextStyle(color: isDark ? Colors.white : Colors.black)),
      );
    }
    final pending = _reports.where((r) => r['status'] == 'pending').toList();
    final handled = _reports.where((r) => r['status'] != 'pending').toList();

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.all(12),
        children: [
          if (pending.isNotEmpty) ...[
            _buildSectionHeader('待处理 (${pending.length})', Icons.warning_amber,
                Colors.orange, isDark),
            ...pending.map((r) => _buildReportCard(r, isDark)),
          ],
          if (pending.isEmpty)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(32), child: Text('暂无待处理举报'))),
          if (handled.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSectionHeader(
                '已处理 (${handled.length})', Icons.history, Colors.grey, isDark),
            ...handled.map((r) => _buildHandledReportCard(r, isDark)),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
      String title, IconData icon, Color color, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white54 : Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportCard(dynamic report, bool isDark) {
    final isReply = report['target_type'] == 'reply';
    final reasonMap = {
      'spam': '垃圾广告',
      'porn': '色情低俗',
      'violence': '暴力血腥',
      'fake': '虚假信息',
      'privacy': '侵犯隐私',
      'harassment': '人身攻击',
      'other': '其他',
    };
    final reasonLabel = reasonMap[report['reason']] ?? report['reason'] ?? '未知';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: isDark ? Colors.grey[850] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isReply
                        ? Colors.purple.withOpacity(0.15)
                        : Colors.blue.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isReply
                        ? '评论 #${report['target_id']}'
                        : '帖子 #${report['target_id']}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isReply ? Colors.purple : Colors.blue,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  report['reporter']?['nickname'] ?? '匿名',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white38 : Colors.grey[500],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              reasonLabel,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () async {
                    try {
                      final dio = context.read<AuthProvider>().dio;
                      await dio.put(
                        '/reports/${report['id']}/handle',
                        data: {'status': 'ignored'},
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('已忽略'),
                              backgroundColor: Colors.grey),
                        );
                        setState(() => _reports
                            .removeWhere((r) => r['id'] == report['id']));
                      }
                    } catch (_) {}
                  },
                  icon: const Icon(Icons.close, size: 16, color: Colors.grey),
                  label: const Text('忽略',
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _handleReport(report),
                  icon: const Icon(Icons.delete_outline,
                      size: 16, color: Colors.white),
                  label: const Text('处理',
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red[400],
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHandledReportCard(dynamic report, bool isDark) {
    final isHandled = report['status'] == 'handled';
    final reasonMap = {
      'spam': '垃圾广告',
      'porn': '色情低俗',
      'violence': '暴力血腥',
      'fake': '虚假信息',
      'privacy': '侵犯隐私',
      'harassment': '人身攻击',
      'other': '其他',
    };
    final reasonLabel = reasonMap[report['reason']] ?? report['reason'] ?? '未知';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isDark ? Colors.grey[850] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isHandled ? Icons.check_circle : Icons.remove_circle,
                  size: 14,
                  color: isHandled ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 6),
                Text(
                  reasonLabel,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.grey[600],
                  ),
                ),
                const Spacer(),
                Text(
                  isHandled ? '已删除' : '已忽略',
                  style: TextStyle(
                    fontSize: 11,
                    color: isHandled ? Colors.green[300] : Colors.grey[500],
                  ),
                ),
              ],
            ),
            if (report['delete_reason'] != null &&
                report['delete_reason'].toString().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '理由: ${report['delete_reason']}',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white30 : Colors.grey[500],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
