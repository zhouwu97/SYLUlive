import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/course_evaluation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/course_evaluation_provider.dart';
import 'course_evaluation_form_sheet.dart';

/// 课表课程详情中的教师评价入口。
///
/// 放在课程详情周次/备注之后，不包裹原有课程信息为新卡片。
/// 网络失败只在本区域内显示可重试错误，不影响课表主体信息。
///
/// 状态支持：loading、error/retry、无匹配、已匹配、
/// pending、published、needs_edit（含驳回原因）。
class CourseEvaluationSection extends StatefulWidget {
  final String courseName;
  final String teacherName;

  const CourseEvaluationSection({
    super.key,
    required this.courseName,
    this.teacherName = '',
  });

  @override
  State<CourseEvaluationSection> createState() =>
      _CourseEvaluationSectionState();
}

class _CourseEvaluationSectionState extends State<CourseEvaluationSection> {
  CourseEvaluationResolveResult? _result;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    final provider = context.read<CourseEvaluationProvider>();
    final cached = provider.resolveCacheFor(
      widget.courseName,
      widget.teacherName,
    );
    if (cached != null) {
      setState(() {
        _result = cached;
        _error = null;
        _loading = false;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await provider.resolveForCourse(
      widget.courseName,
      widget.teacherName,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _result = result;
      if (result == null) {
        _error = provider.resolveErrorFor(
              widget.courseName,
              widget.teacherName,
            ) ??
            '课程评价服务暂不可用';
      }
    });
  }

  Future<void> _openForm() async {
    await CourseEvaluationFormSheet.show(
      context,
      courseName: widget.courseName,
      teacherName: widget.teacherName,
      resolveResult: _result,
      submission: _result?.submission,
    );
    if (!mounted) return;
    // 提交成功后 Provider 会清除解析缓存，这里重新解析拿到最新状态。
    await _resolve();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subColor = isDark ? Colors.white60 : Colors.grey[600];
    final isLoggedIn = context.watch<AuthProvider>().user != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(Icons.rate_review_outlined,
                size: 18, color: Theme.of(context).primaryColor),
            const SizedBox(width: 8),
            Text(
              '课程评价',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (!isLoggedIn)
          _hintRow(isDark, '登录后可评价课程与教师', subColor)
        else if (_loading)
          _hintRow(
            isDark,
            '正在获取课程信息…',
            subColor,
            trailing: const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (_error != null)
          _hintRow(
            isDark,
            _error!,
            subColor,
            trailing: TextButton.icon(
              onPressed: _resolve,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          )
        else
          _buildStatus(isDark, subColor),
      ],
    );
  }

  Widget _buildStatus(bool isDark, Color? subColor) {
    final result = _result;
    if (result == null) {
      return _hintRow(isDark, '课程评价服务暂不可用', subColor);
    }

    final submission = result.submission;
    if (submission != null) {
      return _buildSubmissionStatus(isDark, subColor, submission);
    }

    if (result.requiresConfirmation) {
      return _actionCard(
        isDark,
        icon: Icons.help_outline,
        title: '需要确认标准学科',
        subtitle: result.courseSubjects.length > 1
            ? '「${widget.courseName}」匹配到多个学科，提交前需选择'
            : '「${widget.courseName}」尚未精确收录，提交前需确认',
        actionText: '去确认并评价',
        onTap: _openForm,
      );
    }

    if (result.selectedCourseSubjectId != null) {
      final subjectName = result.courseSubjects
              .where((s) => s.id == result.selectedCourseSubjectId)
              .firstOrNull
              ?.name ??
          widget.courseName;
      if (result.selectedTeacherId != null) {
        final teacherName = result.teachers
                .where((t) => t.id == result.selectedTeacherId)
                .firstOrNull
                ?.name ??
            widget.teacherName;
        return _actionCard(
          isDark,
          icon: Icons.verified_outlined,
          title: '已收录：$subjectName · $teacherName',
          subtitle: '评价提交后直接发布到学科榜',
          actionText: '写评价',
          onTap: _openForm,
        );
      }
      return _actionCard(
        isDark,
        icon: Icons.verified_outlined,
        title: '学科已收录：$subjectName',
        subtitle: result.teachers.isEmpty
            ? '该学科暂无该教师，提交评价后将由管理员审核'
            : '请确认授课教师后提交评价',
        actionText: '评价教师',
        onTap: _openForm,
      );
    }

    return _actionCard(
      isDark,
      icon: Icons.library_add_outlined,
      title: '「${widget.courseName}」尚未收录',
      subtitle: '提交评价将创建新学科与教师，审核通过后公开',
      actionText: '提交评价',
      onTap: _openForm,
    );
  }

  Widget _buildSubmissionStatus(
    bool isDark,
    Color? subColor,
    CourseEvaluationSubmission submission,
  ) {
    switch (submission.status) {
      case CourseEvaluationStatus.published:
        return _submissionCard(
          isDark,
          statusLabel: '已发布',
          statusColor: Colors.green,
          title: '${submission.subjectDisplayName} · ${submission.teacherDisplayName}',
          subtitle: submission.comment.trim().isEmpty
              ? '评价已发布至学科榜'
              : submission.comment,
          star: submission.star,
          actionText: '修改评价',
          onTap: _openForm,
        );
      case CourseEvaluationStatus.pending:
        return _submissionCard(
          isDark,
          statusLabel: '待审核',
          statusColor: Colors.blue,
          title: '${submission.subjectDisplayName} · ${submission.teacherDisplayName}',
          subtitle: submission.willCreateSubject
              ? '将创建新学科「${submission.proposedCourseName.isNotEmpty ? submission.proposedCourseName : submission.courseName}」，等待管理员审核'
              : '等待管理员审核',
          star: submission.star,
          actionText: '编辑',
          onTap: _openForm,
        );
      case CourseEvaluationStatus.needsEdit:
        return _submissionCard(
          isDark,
          statusLabel: '需修改',
          statusColor: Colors.orange,
          title: '${submission.subjectDisplayName} · ${submission.teacherDisplayName}',
          subtitle: submission.reviewReason.trim().isEmpty
              ? '评价被驳回，请修改后重新提交'
              : '驳回原因：${submission.reviewReason}',
          star: submission.star,
          actionText: '修改并重新提交',
          onTap: _openForm,
        );
    }
  }

  // ── 通用组件 ─────────────────────────────────────────────────────

  Widget _hintRow(
    bool isDark,
    String text,
    Color? subColor, {
    Widget? trailing,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, color: subColor, height: 1.4),
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _actionCard(
    bool isDark, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String actionText,
    required VoidCallback onTap,
  }) {
    final isDark0 = isDark;
    final subColor = isDark0 ? Colors.white60 : Colors.grey[600];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDark0 ? Colors.white10 : Colors.grey[200]!,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: Theme.of(context).primaryColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark0 ? Colors.white : Colors.black87,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: subColor),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              child: Text(actionText, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _submissionCard(
    bool isDark, {
    required String statusLabel,
    required Color statusColor,
    required String title,
    required String subtitle,
    required int star,
    required String actionText,
    required VoidCallback onTap,
  }) {
    final subColor = isDark ? Colors.white60 : Colors.grey[600];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: statusColor.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: statusColor.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(fontSize: 10, color: statusColor),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _starRow(star, 12),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: subColor, height: 1.4),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onTap,
                icon: const Icon(Icons.edit_outlined, size: 14),
                label: Text(actionText, style: const TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: statusColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _starRow(int star, double size) {
    if (star <= 0) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (index) {
        return Icon(
          index < star ? Icons.star : Icons.star_border,
          size: size,
          color: Colors.amber,
        );
      }),
    );
  }
}
