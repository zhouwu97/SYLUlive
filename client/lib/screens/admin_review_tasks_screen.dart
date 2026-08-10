import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_page_app_bar.dart';

class AdminReviewTasksScreen extends StatefulWidget {
  const AdminReviewTasksScreen({super.key});

  @override
  State<AdminReviewTasksScreen> createState() => _AdminReviewTasksScreenState();
}

class OptionalListResult {
  final List<dynamic> items;
  final bool failed;

  const OptionalListResult({
    required this.items,
    required this.failed,
  });
}

class _AdminReviewTasksScreenState extends State<AdminReviewTasksScreen> {
  List<dynamic> _pendingTeachers = [];
  List<dynamic> _pendingMajors = [];
  List<dynamic> _pendingInvitations = [];
  List<dynamic> _pendingRemovals = [];
  bool _isLoading = true;
  String? _fatalError;
  String? _warningMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  Future<void> _loadData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _fatalError = null;
      _warningMessage = null;
    });
    try {
      final dio = context.read<AuthProvider>().dio;
      final results = await Future.wait([
        _loadOptionalList(dio, '/teachers/pending'),
        _loadOptionalList(dio, '/majors/pending'),
        _loadOptionalList(dio, '/admin/invitations/pending'),
        _loadOptionalList(dio, '/admin/removals/pending'),
      ]);

      if (!mounted) return;
      final failedCount = results.where((r) => r.failed).length;

      if (!mounted) return;
      setState(() {
        _pendingTeachers = results[0].items;
        _pendingMajors = results[1].items;
        _pendingInvitations = results[2].items;
        _pendingRemovals = results[3].items;
        _isLoading = false;

        if (failedCount == 4) {
          _fatalError = '加载审核任务失败';
        } else if (failedCount > 0) {
          _warningMessage = '部分数据加载失败，下拉或点击可重试';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _fatalError = '加载审核任务失败';
      });
    }
  }

  Future<OptionalListResult> _loadOptionalList(Dio dio, String path) async {
    try {
      final response = await dio.get(
        path,
        options: Options(
          connectTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      return OptionalListResult(
        items: (response.data as List?) ?? [],
        failed: false,
      );
    } catch (_) {
      return const OptionalListResult(items: [], failed: true);
    }
  }

  Future<void> _voteInvitation(dynamic inv) async {
    final dio = context.read<AuthProvider>().dio;
    final messenger = ScaffoldMessenger.of(context);
    final user = (inv['user'] as Map?) ?? {};
    final reason = await _showReasonDialog(
      title: '同意 ${user['nickname'] ?? '该用户'} 成为管理员',
      label: '同意审批理由',
      hint: '例如：候选人信用良好，且持续参与社区维护',
      helperText: '用于审批记录，说明你投同意票的依据。',
      confirmText: '确认同意',
    );
    if (!mounted || reason == null) return;

    try {
      final res = await dio.post(
        '/admin/invitations/${inv['id']}/vote',
        data: {'reason': reason},
      );
      if (!mounted) return;
      final message = (res.data is Map && res.data['message'] != null)
          ? res.data['message'].toString()
          : '已同意';
      messenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.green),
      );
      setState(
          () => _pendingInvitations.removeWhere((i) => i['id'] == inv['id']));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _voteRemoval(dynamic removal) async {
    final dio = context.read<AuthProvider>().dio;
    final messenger = ScaffoldMessenger.of(context);
    final admin = (removal['admin'] as Map?) ?? {};
    final reason = await _showReasonDialog(
      title: '同意罢免 ${admin['nickname'] ?? '该管理员'}',
      label: '同意罢免的投票理由',
      hint: '例如：多次滥用权限，已有明确处理记录',
      helperText: '用于罢免投票记录，请填写可核实的具体依据。',
      confirmText: '确认投票',
    );
    if (!mounted || reason == null) return;

    try {
      final res = await dio.post(
        '/teachers/admin/${admin['id']}/vote-remove',
        data: {'reason': reason},
      );
      if (!mounted) return;
      final message = (res.data is Map && res.data['message'] != null)
          ? res.data['message'].toString()
          : '已投票';
      messenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.green),
      );
      setState(
          () => _pendingRemovals.removeWhere((r) => r['id'] == removal['id']));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
      );
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
        setState(() => _pendingTeachers.removeWhere((t) => t['id'] == id));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(approve ? '已审核通过' : '已拒绝'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _verifyMajor(int id, bool approve) async {
    try {
      final dio = context.read<AuthProvider>().dio;
      if (approve) {
        await dio.put('/majors/$id/verify');
      } else {
        await dio.delete('/majors/$id/reject');
      }
      if (mounted) {
        setState(() => _pendingMajors.removeWhere((m) => m['id'] == id));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(approve ? '已审核通过' : '已拒绝'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
        );
      }
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

    Widget body;
    if (_isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_fatalError != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_fatalError!),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loadData,
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
    } else {
      body = Column(
        children: [
          if (_warningMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: Colors.amber.withValues(alpha: 0.2),
              child: Text(
                _warningMessage!,
                style: TextStyle(
                  color: isDark ? Colors.amber[200] : Colors.amber[900],
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(child: _buildReviewTasksContent(isDark)),
        ],
      );
    }

    return Scaffold(
      appBar: const AppPageAppBar(title: Text('审核代办')),
      body: SafeArea(
        top: false,
        child: body,
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF173B36), AppColors.surfaceSecondaryDark]
              : const [Color(0xFFEAF6F3), Colors.white],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : AppColors.borderNormalLight,
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.brandPrimary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.task_alt_rounded,
              color: AppColors.brandPrimary,
              size: 36,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '审核队列已清空',
            style: AppTextStyles.titleMedium.copyWith(
              color: isDark ? Colors.white : AppColors.textPrimaryLight,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '当前没有需要你处理的教师、专业或管理员协作事项。',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodyMedium.copyWith(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.62)
                  : AppColors.textSecondaryLight,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.tonalIcon(
            onPressed: _loadData,
            style: FilledButton.styleFrom(
              backgroundColor: isDark
                  ? AppColors.brandPrimary.withValues(alpha: 0.24)
                  : const Color(0xFFE5F4F1),
              foregroundColor:
                  isDark ? const Color(0xFF8DE0D3) : AppColors.brandPrimary,
            ),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新任务'),
          ),
        ],
      ),
    );
  }

  Widget _buildReviewTasksContent(bool isDark) {
    final items = <Widget>[];

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
      items.add(
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          color: isDark ? Colors.grey[850] : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(
                backgroundColor: Color(0xFF22C55E),
                child: Icon(Icons.person_add_alt_1, color: Colors.white),
              ),
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
          ),
        ),
      );
    }

    for (final removal in dedupedRemovals) {
      final admin = (removal['admin'] as Map?) ?? {};
      final initiator = (removal['initiator'] as Map?) ?? {};
      final votes = removal['votes'] ?? 0;
      final requiredVotes = removal['required_votes'] ?? 0;
      final canVote = removal['can_vote'] == true;
      final myVote = removal['my_vote'] == true;
      items.add(
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          color: isDark ? Colors.grey[850] : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(
                backgroundColor: Color(0xFFEF4444),
                child: Icon(Icons.person_remove, color: Colors.white),
              ),
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
          ),
        ),
      );
    }

    for (final t in dedupedTeachers) {
      items.add(
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          color: isDark ? Colors.grey[850] : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: const Color(0xFF6366F1),
              child: Text((t['name'] as String? ?? '?').substring(0, 1)),
            ),
            title: Text(t['name'] ?? ''),
            subtitle: Text('老师提交 - ${t['course'] ?? ''}\n一个管理员同意即可通过'),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.check_circle, color: Colors.green),
                  onPressed: () => _verifyTeacher(t['id'], true),
                ),
                IconButton(
                  icon: const Icon(Icons.cancel, color: Colors.red),
                  onPressed: () => _verifyTeacher(t['id'], false),
                ),
              ],
            ),
          ),
        ),
      );
    }
    for (final m in dedupedMajors) {
      items.add(
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          color: isDark ? Colors.grey[850] : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: const Color(0xFFEC4899),
              child: Text((m['name'] as String? ?? '?').substring(0, 1)),
            ),
            title: Text(m['name'] ?? ''),
            subtitle: Text('专业提交 - ${m['level'] ?? ''}\n一个管理员同意即可通过'),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.check_circle, color: Colors.green),
                  onPressed: () => _verifyMajor(m['id'], true),
                ),
                IconButton(
                  icon: const Icon(Icons.cancel, color: Colors.red),
                  onPressed: () => _verifyMajor(m['id'], false),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.section,
            AppSpacing.lg,
            MediaQuery.viewPaddingOf(context).bottom + AppSpacing.xxl,
          ),
          children: [_buildEmptyState(isDark)],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadData,
      child: Scrollbar(
        thumbVisibility: true,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            MediaQuery.viewPaddingOf(context).bottom + AppSpacing.xxl,
          ),
          children: items,
        ),
      ),
    );
  }
}
