import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
import '../config/api_constants.dart';
import 'super_admin_screen.dart';
import 'dart:io' show File;

/// 管理员面板：查看/处理举报、邀请管理员
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<dynamic> _reports = [];
  List<dynamic> _candidates = [];
  List<dynamic> _pendingTeachers = [];
  List<dynamic> _logs = [];
  bool _isLoading = true;
  String? _errorMessage;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final dio = context.read<AuthProvider>().dio;
      final reportsRes = await dio.get('/reports');
      final candidatesRes = await dio.get('/admin/candidates');
      final pendingRes = await dio.get('/teachers/pending');
      final logsRes = await dio.get('/teachers/logs');
      setState(() {
        _reports = (reportsRes.data as List?) ?? [];
        _candidates = (candidatesRes.data as List?) ?? [];
        _pendingTeachers = (pendingRes.data as List?) ?? [];
        _logs = (logsRes.data as List?) ?? [];
        _isLoading = false;
      });
    } on DioException catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.message ?? '加载失败';
      });
    } catch (e) {
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                // 举报信息摘要
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
                        style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.grey[600]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '原因: ${report['reason'] ?? '未知'}',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: isDark ? Colors.white : Colors.black87),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // 处理结果
                TextField(
                  controller: resultController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: '处理结果说明',
                    hintText: '对举报的处理结论',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                // 删除理由
                TextField(
                  controller: deleteReasonController,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: '删除理由（选填，填了会软删除该内容）',
                    hintText: '用户可在申诉中看到此理由',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
      await dio.put('/reports/${report['id']}/handle', data: {
        'status': action,
        'result': resultController.text,
        'delete_reason': deleteReasonController.text,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(action == 'handled' ? '已处理并删除' : '已忽略'),
            backgroundColor: action == 'handled' ? Colors.green : Colors.grey,
          ),
        );
      }
      _loadData();
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

  Future<void> _searchCandidates() async {
    final keyword = _searchController.text.trim();
    try {
      final dio = context.read<AuthProvider>().dio;
      final queryParams = <String, dynamic>{};
      if (keyword.isNotEmpty) queryParams['student_id'] = keyword;
      final res = await dio.get('/admin/candidates', queryParameters: queryParams.isNotEmpty ? queryParams : null);
      if (mounted) {
        setState(() => _candidates = (res.data as List?) ?? []);
      }
    } catch (_) {}
  }

  Future<void> _inviteAdmin(dynamic candidate) async {
    try {
      final dio = context.read<AuthProvider>().dio;
      await dio.post('/admin/invite/${candidate['id']}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('邀请已发送'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      debugPrint('邀请失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final pendingCount = _reports.where((r) => r['status'] == 'pending').length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
        title: const Text('管理员面板'),
      ),
      body: SafeArea(
            child: Column(
              children: [
                // Tab 栏
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: TabBar(
                    controller: _tabController,
                    indicatorColor: Theme.of(context).primaryColor,
                    indicatorWeight: 3,
                    labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    unselectedLabelStyle: const TextStyle(fontSize: 12),
                    dividerColor: Colors.transparent,
                    tabs: [
                      Tab(text: '举报${pendingCount > 0 ? ' ($pendingCount)' : ''}'),
                      const Tab(text: '候选人'),
                      const Tab(text: '审核教师'),
                      const Tab(text: '操作日志'),
                      const Tab(text: '公告'),
                    ],
                  ),
                ),

                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _errorMessage != null
                          ? _buildErrorView(isDark)
                          : TabBarView(
                              controller: _tabController,
                              children: [
                                _buildReportsTab(isDark),
                                _buildCandidatesTab(isDark),
                                _buildTeachersTab(isDark),
                                _buildLogsTab(isDark),
                                _buildAnnouncementTab(),
                              ],
                            ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- 背景 ----
  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.hasBackground && themeProvider.backgroundImage != null) {
      final bgPath = themeProvider.backgroundImage!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(fit: StackFit.expand, children: [
        isAsset
            ? Image.asset('assets/images/$bgPath', fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildDefaultBg(isDark))
            : bgPath.startsWith('/')
                ? Image.file(File(bgPath), fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildDefaultBg(isDark))
                : Image.network(bgPath, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildDefaultBg(isDark)),
        Container(color: isDark ? Colors.black.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.3)),
      ]);
    }
    return _buildDefaultBg(isDark);
  }

  Widget _buildDefaultBg(bool isDark) {
    return Stack(fit: StackFit.expand, children: [
      Image(
        image: ResizeImage(const AssetImage('assets/images/morenbeijing.jpeg'), width: 1080),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [const Color(0xFF1A1A2E), const Color(0xFF16213E), const Color(0xFF0F3460)]
                  : [const Color(0xFF667EEA), const Color(0xFF764BA2), const Color(0xFFF093FB)],
            ),
          ),
        ),
      ),
      Container(color: isDark ? Colors.black.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.25)),
    ]);
  }

  Widget _buildErrorView(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(28), borderRadius: 20, blur: 12, opacity: 0.12,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off, size: 48, color: isDark ? Colors.white30 : Colors.grey[400]),
          const SizedBox(height: 14),
          Text(_errorMessage!, textAlign: TextAlign.center,
            style: TextStyle(color: isDark ? Colors.white60 : Colors.grey[600], fontSize: 15)),
          const SizedBox(height: 18),
          OutlinedButton.icon(onPressed: _loadData, icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
            style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ]),
      ),
    );
  }

  // ---- 举报 Tab ----
  Widget _buildReportsTab(bool isDark) {
    final pending = _reports.where((r) => r['status'] == 'pending').toList();
    final handled = _reports.where((r) => r['status'] != 'pending').toList();

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        children: [
          if (pending.isNotEmpty) ...[
            _buildSectionHeader('待处理 (${pending.length})', Icons.warning_amber, Colors.orange, isDark),
            ...pending.map((r) => _buildReportCard(r, isDark)),
          ],
          if (pending.isEmpty)
            _buildEmptyState('暂无待处理举报', '举报内容将在此显示', Icons.check_circle_outline, isDark),
          if (handled.isNotEmpty) ...[
            const SizedBox(height: 16),
            _buildSectionHeader('已处理 (${handled.length})', Icons.history, Colors.grey, isDark),
            ...handled.map((r) => _buildHandledReportCard(r, isDark)),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
            color: isDark ? Colors.white54 : Colors.grey[600])),
        ],
      ),
    );
  }

  Widget _buildReportCard(dynamic report, bool isDark) {
    final isReply = report['target_type'] == 'reply';
    final reasonMap = {
      'spam': '垃圾广告', 'porn': '色情低俗', 'violence': '暴力血腥',
      'fake': '虚假信息', 'privacy': '侵犯隐私', 'harassment': '人身攻击',
      'other': '其他',
    };
    final reasonLabel = reasonMap[report['reason']] ?? report['reason'] ?? '未知';

    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      borderRadius: 14,
      blur: 8,
      opacity: isDark ? 0.12 : 0.35,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isReply ? Colors.purple.withOpacity(0.15) : Colors.blue.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isReply ? '评论 #${report['target_id']}' : '帖子 #${report['target_id']}',
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
                style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.grey[500]),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            reasonLabel,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () async {
                  try {
                    final dio = context.read<AuthProvider>().dio;
                    await dio.put('/reports/${report['id']}/handle', data: {'status': 'ignored'});
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已忽略'), backgroundColor: Colors.grey),
                      );
                    }
                    _loadData();
                  } catch (_) {}
                },
                icon: const Icon(Icons.close, size: 16, color: Colors.grey),
                label: const Text('忽略', style: TextStyle(color: Colors.grey, fontSize: 13)),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () => _handleReport(report),
                icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white),
                label: const Text('处理', style: TextStyle(color: Colors.white, fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red[400],
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHandledReportCard(dynamic report, bool isDark) {
    final isHandled = report['status'] == 'handled';
    final reasonMap = {
      'spam': '垃圾广告', 'porn': '色情低俗', 'violence': '暴力血腥',
      'fake': '虚假信息', 'privacy': '侵犯隐私', 'harassment': '人身攻击',
      'other': '其他',
    };
    final reasonLabel = reasonMap[report['reason']] ?? report['reason'] ?? '未知';

    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      borderRadius: 12,
      blur: 6,
      opacity: isDark ? 0.08 : 0.2,
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
                style: TextStyle(fontSize: 13, color: isDark ? Colors.white54 : Colors.grey[600]),
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
          if (report['delete_reason'] != null && report['delete_reason'].toString().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '理由: ${report['delete_reason']}',
              style: TextStyle(fontSize: 11, color: isDark ? Colors.white30 : Colors.grey[500]),
            ),
          ],
        ],
      ),
    );
  }

  // ---- 候选人 Tab ----
  Widget _buildCandidatesTab(bool isDark) {
    final displayCandidates = _candidates;

    return Column(children: [
      // 搜索栏
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '按学号搜索候选人',
                hintStyle: TextStyle(fontSize: 13, color: isDark ? Colors.white38 : Colors.grey[400]),
                prefixIcon: Icon(Icons.search, size: 18, color: isDark ? Colors.white38 : Colors.grey[400]),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          _searchCandidates();
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.grey[300]!),
                ),
                filled: true,
                fillColor: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.white.withValues(alpha: 0.5),
              ),
              style: TextStyle(fontSize: 14, color: isDark ? Colors.white : Colors.black87),
              onSubmitted: (_) => _searchCandidates(),
            ),
          ),
        ]),
      ),

      // 候选人列表
      Expanded(
        child: displayCandidates.isEmpty
            ? _buildEmptyState('无匹配结果', '尝试其他学号搜索', Icons.person_search, isDark)
            : RefreshIndicator(
                onRefresh: _loadData,
                child: ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
                  itemCount: displayCandidates.length,
                  itemBuilder: (context, index) {
                    final c = displayCandidates[index];
                    final creditScore = c['credit_score'] ?? 0;
                    return GlassContainer(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      borderRadius: 14,
                      blur: 8,
                      opacity: isDark ? 0.12 : 0.35,
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: isDark ? Colors.white12 : Colors.grey[200],
                            child: Text(
                              (c['nickname'] ?? '?').substring(0, 1).toUpperCase(),
                              style: TextStyle(fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(child: Text(c['nickname'] ?? '未知', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15))),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _creditBadgeColor(creditScore).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text('诚信 $creditScore%',
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _creditBadgeColor(creditScore))),
                                  ),
                                ]),
                                const SizedBox(height: 2),
                                Text(c['student_id'] ?? '',
                                  style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : Colors.grey[500])),
                              ],
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () => _inviteAdmin(c),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).primaryColor.withOpacity(0.8),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              elevation: 0,
                            ),
                            child: const Text('邀请', style: TextStyle(fontSize: 13)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
    ]);
  }

  Color _creditBadgeColor(int score) {
    if (score >= 95) return Colors.green;
    if (score >= 90) return Colors.orange;
    return Colors.grey;
  }

  // ---- 审核教师 Tab ----
  Widget _buildTeachersTab(bool isDark) {
    if (_pendingTeachers.isEmpty) {
      return Center(child: Text('暂无待审核教师', style: TextStyle(color: isDark ? Colors.white54 : Colors.grey[600])));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _pendingTeachers.length,
      itemBuilder: (_, i) {
        final t = _pendingTeachers[i];
        return Card(
          color: isDark ? Colors.grey[850] : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: CircleAvatar(backgroundColor: const Color(0xFF6366F1), child: Text((t['name'] as String? ?? '?')[0])),
            title: Text(t['name'] ?? ''),
            subtitle: Text(t['course'] ?? ''),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.check_circle, color: Colors.green), onPressed: () => _verifyTeacher(t['id'], true)),
              IconButton(icon: const Icon(Icons.cancel, color: Colors.red), onPressed: () => _verifyTeacher(t['id'], false)),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _verifyTeacher(int id, bool approve) async {
    try {
      final dio = context.read<AuthProvider>().dio;
      if (approve) {
        await dio.put('/teachers/$id/verify');
      } else {
        await dio.delete('/teachers/$id/reject');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(approve ? '已审核通过' : '已拒绝'), backgroundColor: Colors.green));
        _loadData();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red));
    }
  }

  // ---- 操作日志 Tab ----
  Widget _buildLogsTab(bool isDark) {
    if (_logs.isEmpty) {
      return Center(child: Text('暂无操作日志', style: TextStyle(color: isDark ? Colors.white54 : Colors.grey[600])));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _logs.length,
      itemBuilder: (_, i) {
        final log = _logs[i];
        return Card(
          color: isDark ? Colors.grey[850] : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: ListTile(
            title: Text('${log['admin_name'] ?? '?'}: ${log['action'] ?? ''}', style: const TextStyle(fontSize: 14)),
            subtitle: Text(log['target'] ?? '', style: TextStyle(fontSize: 12, color: Colors.grey)),
            trailing: Text(log['created_at']?.toString().substring(0, 16) ?? '', style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ),
        );
      },
    );
  }

  // ---- 公告 Tab ----
  Widget _buildAnnouncementTab() {
    // TODO: 公告管理界面
    return const Center(child: Text('公告管理开发中'));
  }

  Widget _buildEmptyState(String title, String subtitle, IconData icon, bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(32),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: isDark ? Colors.white60 : Colors.grey[400]),
            const SizedBox(height: 16),
            Text(title, style: TextStyle(fontSize: 18, color: isDark ? Colors.white70 : Colors.grey[600])),
            const SizedBox(height: 8),
            Text(subtitle, style: TextStyle(fontSize: 14, color: isDark ? Colors.white.withOpacity(0.4) : Colors.grey[400])),
          ],
        ),
      ),
    );
  }
}
