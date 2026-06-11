import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../utils/app_feedback.dart';
import '../widgets/glass_container.dart';
import 'dart:io' show File;

class _OptionalListResult {
  final List<dynamic> items;
  final int? statusCode;

  const _OptionalListResult({
    required this.items,
    this.statusCode,
  });
}

/// 管理员面板：查看/处理举报、邀请管理员
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<dynamic> _reports = [];
  List<dynamic> _candidates = [];
  List<dynamic> _pendingTeachers = [];
  List<dynamic> _pendingInvitations = [];
  List<dynamic> _pendingRemovals = [];
  List<dynamic> _logs = [];
  List<dynamic> _pendingMajors = [];
  bool _reportsForbidden = false;
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
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final reportsResult = await _loadOptionalResult(dio, '/reports');
      final candidatesResult =
          await _loadOptionalResult(dio, '/admin/candidates');
      final pendingTeachers =
          await _loadOptionalList(dio, '/teachers/pending', '待审核教师');
      final pendingMajors =
          await _loadOptionalList(dio, '/majors/pending', '待审核专业');
      final pendingInvitations =
          await _loadOptionalList(dio, '/admin/invitations/pending', '管理员邀请代办');
      final pendingRemovals =
          await _loadOptionalList(dio, '/admin/removals/pending', '管理员罢免代办');
      final logs = await _loadOptionalList(dio, '/teachers/logs', '管理员日志');
      if (!mounted) return;
      setState(() {
        _reports = reportsResult.items;
        _candidates = candidatesResult.items;
        _reportsForbidden = reportsResult.statusCode == 403;
        _pendingTeachers = pendingTeachers;
        _pendingMajors = pendingMajors;
        _pendingInvitations = pendingInvitations;
        _pendingRemovals = pendingRemovals;
        _logs = logs;
        _isLoading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = AppFeedback.dioErrorMessage(e, fallback: '加载失败');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<_OptionalListResult> _loadOptionalResult(Dio dio, String path) async {
    try {
      final response = await dio.get(path);
      return _OptionalListResult(
        items: (response.data as List?) ?? const [],
        statusCode: response.statusCode,
      );
    } on DioException catch (e) {
      debugPrint(
          '可选数据加载失败 [$path]: ${e.response?.statusCode} ${e.response?.data ?? e.message}');
      return _OptionalListResult(
        items: const [],
        statusCode: e.response?.statusCode,
      );
    }
  }

  Future<List<dynamic>> _loadOptionalList(
      Dio dio, String path, String label) async {
    try {
      final response = await dio.get(path);
      return (response.data as List?) ?? [];
    } on DioException catch (e) {
      debugPrint(
          '$label 加载失败 [$path]: ${e.response?.statusCode} ${e.response?.data ?? e.message}');
    } catch (e) {
      debugPrint('$label 加载失败 [$path]: $e');
    }
    return [];
  }

  Future<void> _handleReport(dynamic report) async {
    final deleteReasonController = TextEditingController();
    final resultController = TextEditingController();

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
                        style: TextStyle(
                            fontSize: 13,
                            color: isDark ? Colors.white60 : Colors.grey[600]),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '原因: ${report['reason'] ?? '未知'}',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: isDark ? Colors.white : Colors.black87),
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
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
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
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
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
                    borderRadius: BorderRadius.circular(12)),
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
        // 本地移除已处理的举报，不全局刷新
        if (mounted) setState(() => _reports.removeWhere((r) => r['id'] == report['id']));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(action == 'handled' ? '已处理并删除' : '已忽略'),
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

  Future<void> _searchCandidates() async {
    final keyword = _searchController.text.trim();
    try {
      final dio = context.read<AuthProvider>().dio;
      final queryParams = <String, dynamic>{};
      if (keyword.isNotEmpty) queryParams['student_id'] = keyword;
      final res = await dio.get('/admin/candidates',
          queryParameters: queryParams.isNotEmpty ? queryParams : null);
      if (mounted) {
        setState(() => _candidates = (res.data as List?) ?? []);
      }
    } catch (_) {}
  }

  Future<void> _inviteAdmin(dynamic candidate) async {
    final dio = context.read<AuthProvider>().dio;
    final messenger = ScaffoldMessenger.of(context);
    final reason = await _showReasonDialog(
      title: '邀请 ${candidate['nickname'] ?? ''} 成为管理员',
      label: '邀请理由',
      hint: '说明为什么推荐该用户成为管理员',
      confirmText: '发送邀请',
    );
    if (!mounted || reason == null) return;

    try {
      await Future<void>.delayed(Duration.zero);
      await dio
          .post('/admin/invite/${candidate['id']}', data: {'reason': reason});
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
            content: Text('邀请已发送，用户同意后进入管理员代办'), backgroundColor: Colors.green),
      );
      // 本地移除该候选人，不全局刷新
      if (mounted) setState(() => _candidates.removeWhere((c) => c['id'] == candidate['id']));
    } on DioException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(_dioErrorMessage(e, '邀请失败')),
          backgroundColor: Colors.red));
    }
  }

  Future<String?> _showReasonDialog({
    required String title,
    required String label,
    required String hint,
    required String confirmText,
  }) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
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
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
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
    // 推迟到下一帧 dispose，避免对话框退出动画期间 controller 被提前回收
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (result == null || result.trim().isEmpty) return null;
    return result.trim();
  }

  String _dioErrorMessage(DioException e, String fallback) {
    final data = e.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
    if (data is Map && data['message'] != null) {
      return data['message'].toString();
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final pendingCount = _reports.where((r) => r['status'] == 'pending').length;
    final todoCount = _pendingTeachers.length +
        _pendingMajors.length +
        _pendingInvitations.where((i) => i['my_vote'] != true).length +
        _pendingRemovals.where((r) => r['can_vote'] == true).length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(),
        title: const Text('管理员面板'),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildBackground(themeProvider, isDark)),
          SafeArea(
            child: Column(
              children: [
                // Tab 栏
                Container(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: TabBar(
                    controller: _tabController,
                    indicatorColor: Theme.of(context).primaryColor,
                    indicatorWeight: 3,
                    labelStyle: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                    unselectedLabelStyle: const TextStyle(fontSize: 12),
                    dividerColor: Colors.transparent,
                    tabs: [
                      Tab(
                          text:
                              '举报${pendingCount > 0 ? ' ($pendingCount)' : ''}'),
                      const Tab(text: '候选人'),
                      Tab(text: '代办${todoCount > 0 ? ' ($todoCount)' : ''}'),
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
        ],
      ),
    );
  }

  // ---- 背景 ----
  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.isBackgroundVisible && themeProvider.getBackgroundImageFor(context) != null) {
      final bgPath = themeProvider.getBackgroundImageFor(context)!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(fit: StackFit.expand, children: [
        isAsset
            ? Image.asset('assets/images/$bgPath',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildDefaultBg(isDark))
            : bgPath.startsWith('/')
                ? Image.file(File(bgPath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildDefaultBg(isDark))
                : Image.network(bgPath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _buildDefaultBg(isDark)),
        Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.3)),
      ]);
    }
    return _buildDefaultBg(isDark);
  }

  Widget _buildDefaultBg(bool isDark) {
    return Stack(fit: StackFit.expand, children: [
      Image(
        image: ResizeImage(const AssetImage('assets/images/morenbeijing.jpeg'),
            width: 1080),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isDark
                  ? [
                      const Color(0xFF1A1A2E),
                      const Color(0xFF16213E),
                      const Color(0xFF0F3460)
                    ]
                  : [
                      const Color(0xFF667EEA),
                      const Color(0xFF764BA2),
                      const Color(0xFFF093FB)
                    ],
            ),
          ),
        ),
      ),
      Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25)),
    ]);
  }

  Widget _buildErrorView(bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(28),
        borderRadius: 20,
        blur: 12,
        opacity: 0.12,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off,
              size: 48, color: isDark ? Colors.white30 : Colors.grey[400]),
          const SizedBox(height: 14),
          Text(_errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.grey[600],
                  fontSize: 15)),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重试'),
            style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
          ),
        ]),
      ),
    );
  }

  // ---- 举报 Tab ----
  Widget _buildReportsTab(bool isDark) {
    if (_reportsForbidden) {
      return Center(
        child: GlassContainer(
          padding: const EdgeInsets.all(28),
          borderRadius: 20,
          blur: 12,
          opacity: 0.12,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline,
                size: 48, color: isDark ? Colors.white30 : Colors.grey[500]),
            const SizedBox(height: 14),
            Text('当前账号暂无举报处理权限',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : Colors.black87)),
            const SizedBox(height: 8),
            Text('你仍然可以处理管理员代办、审核教师和专业。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: isDark ? Colors.white54 : Colors.grey[600])),
          ]),
        ),
      );
    }
    final pending = _reports.where((r) => r['status'] == 'pending').toList();
    final handled = _reports.where((r) => r['status'] != 'pending').toList();

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        children: [
          if (pending.isNotEmpty) ...[
            _buildSectionHeader('待处理 (${pending.length})', Icons.warning_amber,
                Colors.orange, isDark),
            ...pending.map((r) => _buildReportCard(r, isDark)),
          ],
          if (pending.isEmpty)
            _buildEmptyState(
                '暂无待处理举报', '举报内容将在此显示', Icons.check_circle_outline, isDark),
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
          Text(title,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white54 : Colors.grey[600])),
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
                    color: isDark ? Colors.white38 : Colors.grey[500]),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            reasonLabel,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : Colors.black87),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () async {
                  try {
                    final dio = context.read<AuthProvider>().dio;
                    await dio.put('/reports/${report['id']}/handle',
                        data: {'status': 'ignored'});
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('已忽略'), backgroundColor: Colors.grey),
                      );
                      // 本地移除该举报
                      if (mounted) setState(() => _reports.removeWhere((r) => r['id'] == report['id']));
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
      'spam': '垃圾广告',
      'porn': '色情低俗',
      'violence': '暴力血腥',
      'fake': '虚假信息',
      'privacy': '侵犯隐私',
      'harassment': '人身攻击',
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
                style: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white54 : Colors.grey[600]),
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
                  color: isDark ? Colors.white30 : Colors.grey[500]),
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
                hintStyle: TextStyle(
                    fontSize: 13,
                    color: isDark ? Colors.white38 : Colors.grey[400]),
                prefixIcon: Icon(Icons.search,
                    size: 18,
                    color: isDark ? Colors.white38 : Colors.grey[400]),
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
                  borderSide: BorderSide(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.grey[300]!),
                ),
                filled: true,
                fillColor: isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.white.withValues(alpha: 0.5),
              ),
              style: TextStyle(
                  fontSize: 14, color: isDark ? Colors.white : Colors.black87),
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
                            backgroundColor:
                                isDark ? Colors.white12 : Colors.grey[200],
                            child: Text(
                              (c['nickname'] ?? '?')
                                  .substring(0, 1)
                                  .toUpperCase(),
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color:
                                      isDark ? Colors.white : Colors.black87),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Expanded(
                                      child: Text(c['nickname'] ?? '未知',
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 15))),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _creditBadgeColor(creditScore)
                                          .withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text('诚信 $creditScore%',
                                        style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: _creditBadgeColor(
                                                creditScore))),
                                  ),
                                ]),
                                const SizedBox(height: 2),
                                Text(c['student_id'] ?? '',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? Colors.white38
                                            : Colors.grey[500])),
                              ],
                            ),
                          ),
                          ElevatedButton(
                            onPressed: () => _inviteAdmin(c),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context)
                                  .primaryColor
                                  .withOpacity(0.8),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              elevation: 0,
                            ),
                            child: const Text('邀请',
                                style: TextStyle(fontSize: 13)),
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

  // ---- 管理员代办 Tab ----
  Widget _buildTeachersTab(bool isDark) {
    final items = <Widget>[];

    // 去重：同一目标只保留最早一条（按列表顺序，先到先保留）
    final seenInviteUsers = <int>{};
    final dedupedInvitations = _pendingInvitations.where((i) {
      final uid = (i['user'] as Map?)?['id'] ?? i['user_id'];
      if (seenInviteUsers.contains(uid)) return false;
      return seenInviteUsers.add(uid);
    }).toList();

    final seenRemovalAdmins = <int>{};
    final dedupedRemovals = _pendingRemovals.where((r) {
      final aid = (r['admin'] as Map?)?['id'] ?? r['admin_id'];
      if (seenRemovalAdmins.contains(aid)) return false;
      return seenRemovalAdmins.add(aid);
    }).toList();

    final seenTeacherNames = <String>{};
    final dedupedTeachers = _pendingTeachers.where((t) {
      final name = (t['name'] ?? '').toString();
      if (seenTeacherNames.contains(name)) return false;
      return seenTeacherNames.add(name);
    }).toList();

    final seenMajorNames = <String>{};
    final dedupedMajors = _pendingMajors.where((m) {
      final name = (m['name'] ?? '').toString();
      if (seenMajorNames.contains(name)) return false;
      return seenMajorNames.add(name);
    }).toList();

    for (final inv in dedupedInvitations) {
      final user = (inv['user'] as Map?) ?? {};
      final inviter = (inv['inviter'] as Map?) ?? {};
      final votes = inv['votes'] ?? 0;
      final requiredVotes = inv['required_votes'] ?? 3;
      final myVote = inv['my_vote'] == true;
      items.add(Card(
        color: isDark ? Colors.grey[850] : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(
                  backgroundColor: Color(0xFF22C55E),
                  child: Icon(Icons.person_add_alt_1, color: Colors.white)),
              title: Text('管理员邀请：${user['nickname'] ?? '未知用户'}'),
              subtitle: Text(
                '邀请人：${inviter['nickname'] ?? '未知'}\n'
                '理由：${inv['reason'] ?? '未填写'}\n'
                '进度：$votes/$requiredVotes',
              ),
              isThreeLine: true,
              trailing: myVote
                  ? const Chip(label: Text('已同意'))
                  : FilledButton(
                      onPressed: () => _voteInvitation(inv),
                      child: const Text('同意'),
                    ),
            ),
          ]),
        ),
      ));
    }

    for (final removal in dedupedRemovals) {
      final admin = (removal['admin'] as Map?) ?? {};
      final initiator = (removal['initiator'] as Map?) ?? {};
      final votes = removal['votes'] ?? 0;
      final requiredVotes = removal['required_votes'] ?? 0;
      final canVote = removal['can_vote'] == true;
      final myVote = removal['my_vote'] == true;
      items.add(Card(
        color: isDark ? Colors.grey[850] : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(
                  backgroundColor: Color(0xFFEF4444),
                  child: Icon(Icons.person_remove, color: Colors.white)),
              title: Text('罢免管理员：${admin['nickname'] ?? '未知管理员'}'),
              subtitle: Text(
                '申请人：${initiator['nickname'] ?? '未知'}\n'
                '理由：${removal['reason'] ?? '未填写'}\n'
                '进度：$votes/$requiredVotes',
              ),
              isThreeLine: true,
              trailing: myVote
                  ? const Chip(label: Text('已投票'))
                  : FilledButton(
                      onPressed: canVote ? () => _voteRemoval(removal) : null,
                      style:
                          FilledButton.styleFrom(backgroundColor: Colors.red),
                      child: const Text('同意罢免'),
                    ),
            ),
          ]),
        ),
      ));
    }

    for (final t in dedupedTeachers) {
      items.add(Card(
        color: isDark ? Colors.grey[850] : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ListTile(
          leading: CircleAvatar(
              backgroundColor: const Color(0xFF6366F1),
              child: Text((t['name'] as String? ?? '?')[0])),
          title: Text(t['name'] ?? ''),
          subtitle: Text('老师提交 - ${t['course'] ?? ''}\n一个管理员同意即可通过'),
          isThreeLine: true,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                icon: const Icon(Icons.check_circle, color: Colors.green),
                onPressed: () => _verifyTeacher(t['id'], true)),
            IconButton(
                icon: const Icon(Icons.cancel, color: Colors.red),
                onPressed: () => _verifyTeacher(t['id'], false)),
          ]),
        ),
      ));
    }
    for (final m in dedupedMajors) {
      items.add(Card(
        color: isDark ? Colors.grey[850] : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ListTile(
          leading: CircleAvatar(
              backgroundColor: const Color(0xFFEC4899),
              child: Text((m['name'] as String? ?? '?')[0])),
          title: Text(m['name'] ?? ''),
          subtitle: Text('专业提交 - ${m['level'] ?? ''}\n一个管理员同意即可通过'),
          isThreeLine: true,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                icon: const Icon(Icons.check_circle, color: Colors.green),
                onPressed: () => _verifyMajor(m['id'], true)),
            IconButton(
                icon: const Icon(Icons.cancel, color: Colors.red),
                onPressed: () => _verifyMajor(m['id'], false)),
          ]),
        ),
      ));
    }
    if (items.isEmpty)
      return Center(
          child: Text('暂无管理员代办',
              style: TextStyle(
                  color: isDark ? Colors.white54 : Colors.grey[600])));
    return ListView(padding: const EdgeInsets.all(12), children: items);
  }

  Future<void> _voteInvitation(dynamic inv) async {
    final dio = context.read<AuthProvider>().dio;
    final messenger = ScaffoldMessenger.of(context);
    final user = (inv['user'] as Map?) ?? {};
    final reason = await _showReasonDialog(
      title: '同意 ${user['nickname'] ?? '该用户'} 成为管理员',
      label: '审批理由',
      hint: '说明同意该用户成为管理员的原因',
      confirmText: '确认同意',
    );
    if (!mounted || reason == null) return;

    try {
      await Future<void>.delayed(Duration.zero);
      final res = await dio.post('/admin/invitations/${inv['id']}/vote', data: {
        'reason': reason,
      });
      if (!mounted) return;
      final message = (res.data is Map && res.data['message'] != null)
          ? res.data['message'].toString()
          : '已同意';
      messenger.showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.green));
      // 本地移除该代办
      if (mounted) setState(() => _pendingInvitations.removeWhere((i) => i['id'] == inv['id']));
    } on DioException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(_dioErrorMessage(e, '操作失败')),
          backgroundColor: Colors.red));
    }
  }

  Future<void> _voteRemoval(dynamic removal) async {
    final dio = context.read<AuthProvider>().dio;
    final messenger = ScaffoldMessenger.of(context);
    final admin = (removal['admin'] as Map?) ?? {};
    final reason = await _showReasonDialog(
      title: '同意罢免 ${admin['nickname'] ?? '该管理员'}',
      label: '投票理由',
      hint: '说明同意罢免的原因',
      confirmText: '确认投票',
    );
    if (!mounted || reason == null) return;

    try {
      await Future<void>.delayed(Duration.zero);
      final res = await dio.post(
        '/teachers/admin/${admin['id']}/vote-remove',
        data: {'reason': reason},
      );
      if (!mounted) return;
      final message = (res.data is Map && res.data['message'] != null)
          ? res.data['message'].toString()
          : '已投票';
      messenger.showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.green));
      // 本地移除该罢免投票
      if (mounted) setState(() => _pendingRemovals.removeWhere((r) => r['id'] == removal['id']));
    } on DioException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
          content: Text(_dioErrorMessage(e, '操作失败')),
          backgroundColor: Colors.red));
    }
  }

  Future<void> _verifyMajor(int id, bool approve) async {
    try {
      final dio = context.read<AuthProvider>().dio;
      if (approve)
        await dio.put('/majors/$id/verify');
      else
        await dio.delete('/majors/$id/reject');
      if (mounted) {
        // 本地移除，不全局刷新
        if (mounted) setState(() => _pendingMajors.removeWhere((m) => m['id'] == id));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(approve ? '已审核通过' : '已拒绝'),
            backgroundColor: Colors.green));
      }
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red));
    }
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
        // 本地移除，不全局刷新
        if (mounted) setState(() => _pendingTeachers.removeWhere((t) => t['id'] == id));
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(approve ? '已审核通过' : '已拒绝'),
            backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red));
    }
  }

  // ---- 操作日志 Tab ----
  Widget _buildLogsTab(bool isDark) {
    if (_logs.isEmpty) {
      return Center(
          child: Text('暂无操作日志',
              style: TextStyle(
                  color: isDark ? Colors.white54 : Colors.grey[600])));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _logs.length,
      itemBuilder: (_, i) {
        final log = _logs[i];
        return Card(
          color: isDark ? Colors.grey[850] : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: ListTile(
            title: Text('${log['admin_name'] ?? '?'}: ${log['action'] ?? ''}',
                style: const TextStyle(fontSize: 14)),
            subtitle: Text(log['target'] ?? '',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            trailing: Text(log['created_at']?.toString().substring(0, 16) ?? '',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ),
        );
      },
    );
  }

  // ---- 公告 Tab ----
  String _announcementDraftKey([int? id]) =>
      'announcement_draft_${id ?? 'new'}';

  Widget _buildAnnouncementTab() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return StatefulBuilder(builder: (context, setLocalState) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: ElevatedButton.icon(
              onPressed: () => _showAnnouncementEditor(context)
                  .then((_) => setLocalState(() {})),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('发布公告'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          Expanded(
              child: FutureBuilder(
            future: context.read<AuthProvider>().dio.get('/announcements'),
            builder: (_, snap) {
              if (!snap.hasData)
                return const Center(child: CircularProgressIndicator());
              final list = (snap.data!.data as List?) ?? [];
              if (list.isEmpty)
                return Center(
                    child: Text('暂无公告',
                        style: TextStyle(
                            color:
                                isDark ? Colors.white54 : Colors.grey[600])));
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final a = list[i];
                  return Card(
                    color: isDark ? Colors.grey[850] : Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    child: ListTile(
                      onTap: () =>
                          _showAnnouncementEditor(context, announcement: a)
                              .then((_) => setLocalState(() {})),
                      title: Text(a['title'] ?? '',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(a['content'] ?? '',
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: PopupMenuButton(
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(
                            value: 'pin',
                            child: Text(a['is_pinned'] == true ? '取消置顶' : '置顶'),
                          ),
                          const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除',
                                  style: TextStyle(color: Colors.red))),
                        ],
                        onSelected: (v) async {
                          final dio = context.read<AuthProvider>().dio;
                          if (v == 'edit') {
                            await _showAnnouncementEditor(context,
                                announcement: a);
                            setLocalState(() {});
                          } else if (v == 'pin') {
                            await dio.put('/announcements/${a['id']}', data: {
                              'is_pinned': !(a['is_pinned'] == true),
                            });
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                    a['is_pinned'] == true ? '已取消置顶' : '已置顶公告'),
                                backgroundColor: Colors.green,
                              ),
                            );
                            setLocalState(() {});
                          } else if (v == 'delete') {
                            await dio.delete('/announcements/${a['id']}');
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('公告已删除'),
                                backgroundColor: Colors.green,
                              ),
                            );
                            setLocalState(() {});
                          }
                        },
                      ),
                    ),
                  );
                },
              );
            },
          )),
        ],
      );
    });
  }

  Future<void> _showAnnouncementEditor(BuildContext context,
      {Map<dynamic, dynamic>? announcement}) async {
    final titleCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    final isEditing = announcement != null;
    bool isPinned = announcement?['is_pinned'] == true;
    final draftKey = _announcementDraftKey(announcement?['id'] as int?);
    final prefs = await SharedPreferences.getInstance();
    final draftTitle = prefs.getString('${draftKey}_title');
    final draftContent = prefs.getString('${draftKey}_content');
    final draftPinned = prefs.getBool('${draftKey}_pinned');

    titleCtrl.text = draftTitle ?? (announcement?['title']?.toString() ?? '');
    contentCtrl.text =
        draftContent ?? (announcement?['content']?.toString() ?? '');
    isPinned = draftPinned ?? isPinned;

    Future<void> saveDraft() async {
      await prefs.setString('${draftKey}_title', titleCtrl.text);
      await prefs.setString('${draftKey}_content', contentCtrl.text);
      await prefs.setBool('${draftKey}_pinned', isPinned);
    }

    void draftListener() {
      saveDraft();
    }

    titleCtrl.addListener(draftListener);
    contentCtrl.addListener(draftListener);

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(isEditing ? '编辑公告' : '发布公告'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                      labelText: '标题', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(
                  controller: contentCtrl,
                  maxLines: 6,
                  decoration: const InputDecoration(
                      labelText: '内容', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              SwitchListTile(
                value: isPinned,
                contentPadding: EdgeInsets.zero,
                title: const Text('置顶公告'),
                subtitle: const Text('首页优先展示置顶公告'),
                onChanged: (value) async {
                  setDialogState(() => isPinned = value);
                  await saveDraft();
                },
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('关闭')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(isEditing ? '保存' : '发布')),
          ],
        ),
      ),
    );
    titleCtrl.removeListener(draftListener);
    contentCtrl.removeListener(draftListener);

    if (ok == true &&
        (titleCtrl.text.isNotEmpty || contentCtrl.text.isNotEmpty)) {
      final dio = context.read<AuthProvider>().dio;
      if (isEditing) {
        await dio.put('/announcements/${announcement['id']}', data: {
          'title': titleCtrl.text,
          'content': contentCtrl.text,
          'is_pinned': isPinned,
        });
      } else {
        await dio.post('/announcements', data: {
          'title': titleCtrl.text,
          'content': contentCtrl.text,
          'is_pinned': isPinned,
        });
      }
      await prefs.remove('${draftKey}_title');
      await prefs.remove('${draftKey}_content');
      await prefs.remove('${draftKey}_pinned');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(isEditing ? '公告已更新' : '公告已发布'),
            backgroundColor: Colors.green));
        _loadData();
      }
    }
  }

  Widget _buildEmptyState(
      String title, String subtitle, IconData icon, bool isDark) {
    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(32),
        borderRadius: 20,
        blur: 15,
        opacity: 0.1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 64, color: isDark ? Colors.white60 : Colors.grey[400]),
            const SizedBox(height: 16),
            Text(title,
                style: TextStyle(
                    fontSize: 18,
                    color: isDark ? Colors.white70 : Colors.grey[600])),
            const SizedBox(height: 8),
            Text(subtitle,
                style: TextStyle(
                    fontSize: 14,
                    color: isDark
                        ? Colors.white.withOpacity(0.4)
                        : Colors.grey[400])),
          ],
        ),
      ),
    );
  }
}
