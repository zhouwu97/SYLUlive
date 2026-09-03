import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_page_app_bar.dart';
import '../widgets/canteen/canteen_pending_card.dart';

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

/// 课程评价待审核提交的客户端视图。
/// 字段与服务端 SubmissionView 一一对应。
class _PendingCourseEvaluation {
  final int id;
  final String courseName;
  final String courseSubjectName;
  final bool willCreateSubject;
  final String proposedCourseName;
  final String teacherName;
  final int star;
  final String comment;
  final int revision;
  final String source;

  const _PendingCourseEvaluation({
    required this.id,
    required this.courseName,
    required this.courseSubjectName,
    required this.willCreateSubject,
    required this.proposedCourseName,
    required this.teacherName,
    required this.star,
    required this.comment,
    required this.revision,
    required this.source,
  });

  factory _PendingCourseEvaluation.fromJson(Map<String, dynamic> json) {
    return _PendingCourseEvaluation(
      id: (json['id'] as num?)?.toInt() ?? 0,
      courseName: json['course_name']?.toString() ?? '',
      courseSubjectName: json['course_subject_name']?.toString() ?? '',
      willCreateSubject: json['will_create_subject'] == true,
      proposedCourseName: json['proposed_course_name']?.toString() ?? '',
      teacherName: json['teacher_name']?.toString() ?? '',
      star: (json['star'] as num?)?.toInt() ?? 0,
      comment: json['comment']?.toString() ?? '',
      revision: (json['revision'] as num?)?.toInt() ?? 1,
      source: json['source']?.toString() ?? 'schedule',
    );
  }

  String get subjectLabel {
    if (willCreateSubject || courseSubjectName.isEmpty) {
      final proposed =
          proposedCourseName.isNotEmpty ? proposedCourseName : courseName;
      return '将创建新学科「$proposed」';
    }
    return '候选学科：$courseSubjectName';
  }
}

class _AdminReviewTasksScreenState extends State<AdminReviewTasksScreen> {
  List<dynamic> _pendingTeachers = [];
  List<dynamic> _pendingMajors = [];
  List<dynamic> _pendingInvitations = [];
  List<dynamic> _pendingRemovals = [];
  List<dynamic> _pendingCanteens = [];
  List<_PendingCourseEvaluation> _pendingCourseEvaluations = [];
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
        _loadOptionalCanteens(dio),
        _loadOptionalCourseEvaluations(dio),
      ]);

      if (!mounted) return;
      final failedCount = results.where((r) => r.failed).length;

      if (!mounted) return;
      setState(() {
        _pendingTeachers = results[0].items;
        _pendingMajors = results[1].items;
        _pendingInvitations = results[2].items;
        _pendingRemovals = results[3].items;
        _pendingCanteens = results[4].items;
        _pendingCourseEvaluations =
            (results[5].items as List<_PendingCourseEvaluation>);
        _isLoading = false;

        if (failedCount == results.length) {
          _fatalError = '加载审核任务失败';
        } else if (failedCount > 0) {
          _warningMessage = '部分数据加载失败，下拉或点击可重试';
        }
      });
      await _resolveCanteenCreators();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _fatalError = '加载审核任务失败';
      });
    }
  }

  /// 兼容未上线 creator_name 的服务端：用 /user/:id 补全提交人昵称。
  Future<void> _resolveCanteenCreators() async {
    final missingIds = <int>{};
    for (final c in _pendingCanteens) {
      final name = (c['creator_name'] ?? '').toString();
      final createdBy = (c['created_by'] as num?)?.toInt() ?? 0;
      if (name.isEmpty && createdBy != 0) missingIds.add(createdBy);
    }
    if (missingIds.isEmpty) return;

    final dio = context.read<AuthProvider>().dio;
    final names = <int, String>{};
    await Future.wait(missingIds.map((id) async {
      try {
        final res = await dio.get('/user/$id');
        final data = res.data;
        final nickname = (data is Map ? data['nickname']?.toString() : null);
        if (nickname != null && nickname.isNotEmpty) {
          names[id] = nickname;
        }
      } catch (_) {
        // 单个用户解析失败不影响列表展示
      }
    }));
    if (!mounted || names.isEmpty) return;
    setState(() {
      for (final c in _pendingCanteens) {
        final createdBy = (c['created_by'] as num?)?.toInt() ?? 0;
        final name = (c['creator_name'] ?? '').toString();
        if (name.isEmpty && names.containsKey(createdBy)) {
          c['creator_name'] = names[createdBy];
        }
      }
    });
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

  /// 食堂待审接口返回 {items: [...]}，与其他列表接口的裸数组不同。
  Future<OptionalListResult> _loadOptionalCanteens(Dio dio) async {
    try {
      final response = await dio.get(
        '/canteens/pending',
        options: Options(
          connectTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final data = response.data;
      final items = (data is Map) ? data['items'] : null;
      return OptionalListResult(
        items: (items as List?) ?? [],
        failed: items == null,
      );
    } catch (_) {
      return const OptionalListResult(items: [], failed: true);
    }
  }

  /// 课程评价待审接口返回 {items: [...], next_cursor, has_more}。
  /// 待办列表只取第一页：管理员处理完当前批次后下拉刷新即可。
  Future<OptionalListResult> _loadOptionalCourseEvaluations(Dio dio) async {
    try {
      final response = await dio.get(
        '/admin/course-evaluations/pending',
        queryParameters: {'limit': 20},
        options: Options(
          connectTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      final data = response.data;
      final items = (data is Map) ? data['items'] : null;
      if (items is! List) {
        return const OptionalListResult(items: [], failed: true);
      }
      final parsed = items
          .whereType<Map>()
          .map((raw) =>
              _PendingCourseEvaluation.fromJson(Map<String, dynamic>.from(raw)))
          .where((item) => item.id > 0)
          .toList();
      return OptionalListResult(items: parsed, failed: false);
    } catch (_) {
      return const OptionalListResult(items: [], failed: true);
    }
  }

  /// 判断错误是否为 revision 冲突（409）：评价已被用户修改或他人处理。
  bool _isRevisionConflict(Object error) {
    if (error is! DioException) return false;
    if (error.response?.statusCode != 409) return false;
    final data = error.response?.data;
    return data is Map &&
        data['code']?.toString() == 'course_evaluation_revision_conflict';
  }

  /// 审核通过课程评价。通过时携带 revision，过期返回 409。
  Future<void> _approveCourseEvaluation(
      _PendingCourseEvaluation evaluation) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dio = context.read<AuthProvider>().dio;
      await dio.put(
        '/admin/course-evaluations/${evaluation.id}/approve',
        data: {'revision': evaluation.revision},
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('课程评价已通过并发布'),
          backgroundColor: Colors.green,
        ),
      );
      // 成功只移除对应任务，其余待办保持不动。
      setState(() => _pendingCourseEvaluations =
          _pendingCourseEvaluations.where((e) => e.id != evaluation.id).toList());
    } on DioException catch (e) {
      if (!mounted) return;
      if (_isRevisionConflict(e)) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('该评价已被修改或处理，请下拉刷新后重试'),
          ),
        );
        return; // 409 时保留任务，等待刷新。
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
      );
    }
  }

  /// 驳回课程评价。原因必填 1-500 字符，驳回后用户可修改重提。
  Future<void> _rejectCourseEvaluation(
      _PendingCourseEvaluation evaluation) async {
    final messenger = ScaffoldMessenger.of(context);
    final reason = await _showCourseEvaluationRejectDialog(evaluation);
    if (!mounted || reason == null) return;

    try {
      final dio = context.read<AuthProvider>().dio;
      await dio.put(
        '/admin/course-evaluations/${evaluation.id}/reject',
        data: {'revision': evaluation.revision, 'reason': reason},
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('已驳回，用户可修改后重新提交'),
          backgroundColor: Colors.green,
        ),
      );
      setState(() => _pendingCourseEvaluations =
          _pendingCourseEvaluations.where((e) => e.id != evaluation.id).toList());
    } on DioException catch (e) {
      if (!mounted) return;
      if (_isRevisionConflict(e)) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('该评价已被修改或处理，请下拉刷新后重试'),
          ),
        );
        return;
      }
      final data = e.response?.data;
      final message = data is Map && data['error'] != null
          ? data['error'].toString()
          : '操作失败';
      messenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
      );
    }
  }

  /// 驳回原因对话框：原因必填（1-500 字符）。
  Future<String?> _showCourseEvaluationRejectDialog(
      _PendingCourseEvaluation evaluation) {
    final controller = TextEditingController();
    String? errorText;
    return showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('驳回「${evaluation.courseName}」评价？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('驳回后该评价转入"需修改"，用户可修改后重新提交。'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: '驳回原因（必填）',
                  hintText: '例如：课程名与学科不符、评价内容与教学无关',
                  errorText: errorText,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (errorText != null) {
                    setDialogState(() => errorText = null);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setDialogState(() => errorText = '请填写 1-500 字的驳回原因');
                  return;
                }
                Navigator.pop(ctx, value);
              },
              child: const Text('确认驳回'),
            ),
          ],
        ),
      ),
    );
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

  Future<void> _approveCanteen(dynamic canteen) async {
    final id = canteen['id'] as int?;
    if (id == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dio = context.read<AuthProvider>().dio;
      final res = await dio.post('/canteens/$id/approve');
      if (!mounted) return;
      final message = (res.data is Map && res.data['message'] != null)
          ? res.data['message'].toString()
          : '审核已通过';
      messenger.showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.green),
      );
      setState(() => _pendingCanteens.removeWhere((c) => c['id'] == id));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _rejectCanteen(dynamic canteen) async {
    final id = canteen['id'] as int?;
    if (id == null) return;
    final name = (canteen['name'] ?? '').toString();
    final messenger = ScaffoldMessenger.of(context);

    final reason = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text('驳回「$name」？'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('驳回后该食堂提交将被删除，提交者会收到通知。'),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '驳回原因（选填）',
                  hintText: '例如：名称重复、信息不完整',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () =>
                  Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确认驳回'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;

    try {
      final dio = context.read<AuthProvider>().dio;
      await dio.delete(
        '/canteens/$id/pending',
        data: {'reason': reason ?? ''},
      );
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('已驳回'), backgroundColor: Colors.green),
      );
      setState(() => _pendingCanteens.removeWhere((c) => c['id'] == id));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('操作失败'), backgroundColor: Colors.red),
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
      appBar: const AppPageAppBar(title: Text('审核待办')),
      body: SafeArea(
        top: false,
        child: body,
      ),
    );
  }

  /// 课程评价待审卡片：展示课程名、候选学科/将创建新学科、教师、
  /// 星级、评论、revision 和来源；通过携带 revision，驳回必填原因。
  Widget _buildCourseEvaluationCard(
    _PendingCourseEvaluation evaluation,
    bool isDark,
  ) {
    final subColor =
        isDark ? Colors.white.withValues(alpha: 0.62) : Colors.grey[600];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: isDark ? Colors.grey[850] : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 18,
                  backgroundColor: Color(0xFF6366F1),
                  child: Icon(Icons.rate_review_outlined,
                      color: Colors.white, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '课程评价：${evaluation.courseName} · ${evaluation.teacherName}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              evaluation.subjectLabel,
              style: TextStyle(fontSize: 13, color: subColor),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                ...List.generate(5, (index) {
                  return Icon(
                    index < evaluation.star ? Icons.star : Icons.star_border,
                    size: 16,
                    color: Colors.amber,
                  );
                }),
                const SizedBox(width: 8),
                Text(
                  'revision v${evaluation.revision} · 来源：${evaluation.source == 'schedule' ? '教务课表' : evaluation.source}',
                  style: TextStyle(fontSize: 12, color: subColor),
                ),
              ],
            ),
            if (evaluation.comment.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                evaluation.comment,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white70 : Colors.black87,
                  height: 1.4,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () => _rejectCourseEvaluation(evaluation),
                  icon: const Icon(Icons.cancel_outlined,
                      color: Colors.red, size: 18),
                  label: const Text('驳回', style: TextStyle(color: Colors.red)),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => _approveCourseEvaluation(evaluation),
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('通过并发布'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {    return Container(
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
            '当前没有需要你处理的课程评价、教师、专业、食堂提交或管理员协作事项。',
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

    for (final evaluation in _pendingCourseEvaluations) {
      items.add(
        _buildCourseEvaluationCard(evaluation, isDark),
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
              backgroundColor: AppColors.brandPrimary,
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
    for (final c in _pendingCanteens) {
      items.add(
        CanteenPendingCard(
          canteen: (c as Map).cast<String, dynamic>(),
          isDark: isDark,
          onApprove: () => _approveCanteen(c),
          onReject: () => _rejectCanteen(c),
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
