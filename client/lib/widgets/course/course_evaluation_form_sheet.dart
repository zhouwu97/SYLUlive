import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/course_evaluation.dart';
import '../../providers/auth_provider.dart';
import '../../providers/course_evaluation_provider.dart';
import '../rating_detail/rating_star_picker.dart';

/// 课程评价表单。
///
/// 表单顺序固定为"选择标准学科 → 确认/选择教师 → 星级 → 评论 → 提交"。
/// 多候选学科、空教师名与多教师名必须由用户显式确认；
/// 创建新学科/新教师只作为明确选择，不自动提交。
///
/// 编辑模式（传入既有 submission）复用同一表单：
/// pending / needs_edit 编辑后回到 pending，published 直接更新公开评价。
class CourseEvaluationFormSheet extends StatefulWidget {
  final String courseName;
  final String initialTeacherName;
  final CourseEvaluationResolveResult? resolveResult;
  final CourseEvaluationSubmission? submission;

  const CourseEvaluationFormSheet({
    super.key,
    required this.courseName,
    this.initialTeacherName = '',
    this.resolveResult,
    this.submission,
  });

  /// 以 BottomSheet 形式打开表单。
  static Future<void> show(
    BuildContext context, {
    required String courseName,
    String teacherName = '',
    CourseEvaluationResolveResult? resolveResult,
    CourseEvaluationSubmission? submission,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => CourseEvaluationFormSheet(
        courseName: courseName,
        initialTeacherName: teacherName,
        resolveResult: resolveResult,
        submission: submission,
      ),
    );
  }

  @override
  State<CourseEvaluationFormSheet> createState() =>
      _CourseEvaluationFormSheetState();
}

class _CourseEvaluationFormSheetState extends State<CourseEvaluationFormSheet> {
  late final TextEditingController _teacherNameController;
  late final TextEditingController _commentController;
  late final ScrollController _scrollController;

  /// 学科候选。服务端只返回精确、别名或包含候选，不自动合并模糊课程。
  List<CourseSubjectCandidate> _subjects = const [];

  /// 当前选中学科下的已审核教师。
  List<CourseSubjectTeacher> _teachers = const [];

  int? _selectedSubjectId;
  int? _selectedTeacherId;
  bool _loadingTeachers = false;
  int _star = 0;
  bool _submitting = false;

  /// 教师名输入框展示的教师名是否来自已选教师（未被用户改写）。
  String _lastAutoTeacherName = '';

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    final submission = widget.submission;
    final resolve = widget.resolveResult;

    _subjects = resolve?.courseSubjects ?? const [];
    _star = submission?.star ?? 0;
    _teacherNameController = TextEditingController(
      text: submission?.teacherName.isNotEmpty == true
          ? submission!.teacherName
          : widget.initialTeacherName,
    );
    _commentController = TextEditingController(text: submission?.comment ?? '');

    _selectedSubjectId = _initialSubjectId();
    if (_selectedSubjectId != null) {
      // 初始教师候选：resolve 结果携带当前学科的教师列表。
      if (resolve != null &&
          resolve.selectedCourseSubjectId == _selectedSubjectId &&
          resolve.teachers.isNotEmpty) {
        _teachers = resolve.teachers
            .map((t) => CourseSubjectTeacher(
                  id: t.id,
                  name: t.name,
                  ratingCount: 0,
                  averageStar: 0,
                ))
            .toList();
      }
      _selectedTeacherId = _initialTeacherId();
      if (_selectedTeacherId != null) {
        final matched = _teachers
            .where((t) => t.id == _selectedTeacherId)
            .firstOrNull;
        if (matched != null) {
          _lastAutoTeacherName = matched.name;
          if (_teacherNameController.text.trim().isEmpty) {
            _teacherNameController.text = matched.name;
          }
        }
      } else if (_teachers.where((t) => t.id > 0).length == 1) {
        // 学科下只有一位已审核教师：预选并回填姓名，用户仍可改。
        final only = _teachers.first;
        _selectedTeacherId = only.id;
        _lastAutoTeacherName = only.name;
        if (_teacherNameController.text.trim().isEmpty) {
          _teacherNameController.text = only.name;
        }
      }
      if (_teachers.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadTeachersForSubject(_selectedSubjectId!);
        });
      }
    }
  }

  int? _initialSubjectId() {
    final submission = widget.submission;
    final resolve = widget.resolveResult;
    if (submission?.courseSubjectId != null && submission!.courseSubjectId! > 0) {
      return submission.courseSubjectId;
    }
    if (resolve?.selectedCourseSubjectId != null) {
      return resolve!.selectedCourseSubjectId;
    }
    if (_subjects.length == 1 && _subjects.first.id > 0) {
      return _subjects.first.id;
    }
    return null;
  }

  int? _initialTeacherId() {
    final submission = widget.submission;
    final resolve = widget.resolveResult;
    if (submission?.teacherId != null && submission!.teacherId! > 0) {
      // 只有 ID 属于当前学科的教师列表时才预选。
      if (_teachers.any((t) => t.id == submission.teacherId)) {
        return submission.teacherId;
      }
      return null;
    }
    if (resolve?.selectedTeacherId != null &&
        resolve!.selectedTeacherId! > 0 &&
        _teachers.any((t) => t.id == resolve.selectedTeacherId)) {
      return resolve.selectedTeacherId;
    }
    return null;
  }

  @override
  void dispose() {
    _teacherNameController.dispose();
    _commentController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadTeachersForSubject(int subjectId) async {
    if (!mounted) return;
    setState(() => _loadingTeachers = true);
    final detail = await context
        .read<CourseEvaluationProvider>()
        .loadSubjectDetail(subjectId);
    if (!mounted || _selectedSubjectId != subjectId) return;
    setState(() {
      _teachers = detail?.teachers ?? const [];
      _loadingTeachers = false;
    });
  }

  void _onSubjectChanged(int? subjectId) {
    setState(() {
      _selectedSubjectId = subjectId;
      _selectedTeacherId = null;
      _teachers = const [];
      _loadingTeachers = subjectId != null;
    });
    if (subjectId == null) {
      // 切回"创建新学科"时教师也需要显式确认。
      if (_teacherNameController.text.trim() == _lastAutoTeacherName) {
        _teacherNameController.clear();
        _lastAutoTeacherName = '';
      }
      return;
    }
    _loadTeachersForSubject(subjectId);
  }

  void _onTeacherSelected(CourseSubjectTeacher? teacher) {
    setState(() {
      _selectedTeacherId = teacher?.id;
      if (teacher != null) {
        if (_teacherNameController.text.trim().isEmpty ||
            _teacherNameController.text.trim() == _lastAutoTeacherName) {
          _teacherNameController.text = teacher.name;
          _lastAutoTeacherName = teacher.name;
        }
      } else if (_teacherNameController.text.trim() ==
          _lastAutoTeacherName) {
        _teacherNameController.clear();
        _lastAutoTeacherName = '';
      }
    });
  }

  bool get _looksLikeMultipleTeachers {
    final name = _teacherNameController.text.trim();
    if (name.isEmpty) return false;
    return name.contains(RegExp(r'[、,，/;；]')) || RegExp(r'\s+\S+\s+\S+').hasMatch(name);
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final teacherName = _teacherNameController.text.trim();
    final comment = _commentController.text.trim();

    if (teacherName.isEmpty) {
      _showHint('请填写授课教师姓名');
      return;
    }
    if (_looksLikeMultipleTeachers) {
      _showHint('检测到多个教师姓名，请只填写一位教师');
      return;
    }
    if (_star < 1) {
      _showHint('请选择星级（1-5 星）');
      return;
    }
    if (_subjects.length > 1 && _selectedSubjectId == null) {
      _showHint('存在多个候选学科，请先选择标准学科');
      return;
    }

    final provider = context.read<CourseEvaluationProvider>();
    final auth = context.read<AuthProvider>();
    if (auth.user == null) {
      _showHint('请先登录后再提交评价');
      return;
    }

    setState(() => _submitting = true);
    try {
      CourseEvaluationSubmission? result;
      if (widget.submission != null) {
        result = await provider.update(
          id: widget.submission!.id,
          revision: widget.submission!.revision,
          courseName: widget.courseName,
          teacherName: teacherName,
          star: _star,
          comment: comment,
          courseSubjectId: _selectedSubjectId,
          teacherId: _selectedTeacherId,
        );
      } else {
        result = await provider.submit(
          courseName: widget.courseName,
          teacherName: teacherName,
          star: _star,
          comment: comment,
          courseSubjectId: _selectedSubjectId,
          teacherId: _selectedTeacherId,
        );
      }
      if (!mounted) return;
      final status = result?.status;
      if (status == CourseEvaluationStatus.published) {
        _showHint('评价已发布至学科榜', error: false);
      } else {
        _showHint('评价已提交，等待管理员审核', error: false);
      }
      Navigator.of(context).pop();
    } on CourseEvaluationException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      if (e.isRevisionConflict) {
        _showHint('评价已被更新，请刷新后重试');
      } else if (e.isCandidateRequired) {
        _showHint('请先选择标准学科后再提交');
      } else {
        _showHint(e.message);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _showHint('提交失败，请稍后重试');
    }
  }

  void _showHint(String message, {bool error = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.redAccent : Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subColor = isDark ? Colors.white60 : Colors.grey[600];

    return Padding(
      // 键盘弹出时整体上移，输入框不被遮挡。
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.submission == null ? '课程评价' : '编辑课程评价',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (widget.submission != null)
                      _statusChip(widget.submission!.status, isDark),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Row(
                  children: [
                    Icon(Icons.menu_book_outlined,
                        size: 16, color: subColor),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.courseName,
                        style: TextStyle(
                          fontSize: 13,
                          color: subColor,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSubjectStep(isDark),
                      const SizedBox(height: 16),
                      _buildTeacherStep(isDark),
                      const SizedBox(height: 16),
                      _buildStarStep(isDark),
                      const SizedBox(height: 16),
                      _buildCommentStep(isDark),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            widget.submission == null ? '提交评价' : '保存修改',
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 步骤 1：选择标准学科 ─────────────────────────────────────────

  Widget _buildSubjectStep(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle('1. 选择标准学科', isDark),
        if (_subjects.isEmpty)
          _createOptionTile(
            isDark,
            selected: _selectedSubjectId == null,
            title: '创建新学科「${widget.courseName}」',
            subtitle: '提交后将由管理员审核，审核通过前不公开',
            onTap: () => _onSubjectChanged(null),
          )
        else ...[
          for (final subject in _subjects)
            _createOptionTile(
              isDark,
              selected: _selectedSubjectId == subject.id,
              title: subject.name,
              subtitle: subject.match == CourseSubjectMatchKind.exact
                  ? '与课程名精确匹配'
                  : subject.match == CourseSubjectMatchKind.alias
                      ? '课程名的已知别名'
                      : '与课程名部分匹配，请确认',
              trailingBadge: subject.verified ? '已审核' : null,
              onTap: () => _onSubjectChanged(subject.id),
            ),
          _createOptionTile(
            isDark,
            selected: _selectedSubjectId == null,
            title: '都不是，创建新学科「${widget.courseName}」',
            subtitle: '提交后将由管理员审核，审核通过前不公开',
            onTap: () => _onSubjectChanged(null),
          ),
        ],
      ],
    );
  }

  // ── 步骤 2：确认/选择教师 ────────────────────────────────────────

  Widget _buildTeacherStep(bool isDark) {
    if (_selectedSubjectId == null) {
      // 未选定学科：教师名仍需显式输入。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepTitle('2. 授课教师', isDark),
          TextField(
            controller: _teacherNameController,
            decoration: InputDecoration(
              labelText: '教师姓名',
              hintText: '请填写单独一位教师的姓名',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: _teacherNameController.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空教师姓名',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        setState(() {
                          _teacherNameController.clear();
                          _selectedTeacherId = null;
                          _lastAutoTeacherName = '';
                        });
                      },
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      );
    }

    final verifiedTeachers =
        _teachers.where((t) => t.id > 0).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle('2. 确认/选择教师', isDark),
        if (_loadingTeachers)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (verifiedTeachers.isEmpty)
          _createOptionTile(
            isDark,
            selected: _selectedTeacherId == null,
            title: '该学科暂无已审核教师，将创建新教师',
            subtitle: '审核通过前评价不公开',
            onTap: () => _onTeacherSelected(null),
          )
        else ...[
          for (final teacher in verifiedTeachers)
            _createOptionTile(
              isDark,
              selected: _selectedTeacherId == teacher.id,
              title: teacher.name,
              subtitle: teacher.ratingCount > 0
                  ? '${teacher.averageStar.toStringAsFixed(1)} 分 · ${teacher.ratingCount} 条评价'
                  : '已审核教师，暂无评价',
              onTap: () => _onTeacherSelected(teacher),
            ),
          _createOptionTile(
            isDark,
            selected: _selectedTeacherId == null,
            title: '都不是，创建新教师',
            subtitle: '审核通过前评价不公开',
            onTap: () => _onTeacherSelected(null),
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _teacherNameController,
          decoration: InputDecoration(
            labelText: '教师姓名',
            helperText: _selectedTeacherId != null
                ? '已选择教师，可在此修正姓名'
                : '将创建的新教师姓名',
            helperMaxLines: 2,
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: _teacherNameController.text.trim().isEmpty
                ? null
                : IconButton(
                    tooltip: '清空教师姓名',
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      setState(() {
                        _teacherNameController.clear();
                        _selectedTeacherId = null;
                        _lastAutoTeacherName = '';
                      });
                    },
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // ── 步骤 3：星级 ─────────────────────────────────────────────────

  Widget _buildStarStep(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle('3. 星级', isDark),
        const SizedBox(height: 4),
        RatingStarPicker(
          value: _star,
          onChanged: (star) => setState(() => _star = star),
        ),
      ],
    );
  }

  // ── 步骤 4：评论 ─────────────────────────────────────────────────

  Widget _buildCommentStep(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepTitle('4. 评论（选填）', isDark),
        const SizedBox(height: 4),
        TextField(
          controller: _commentController,
          maxLines: 4,
          maxLength: kCourseEvaluationCommentMaxLength,
          decoration: const InputDecoration(
            hintText: '授课风格、考核方式、内容难度等（最多 200 字）',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  // ── 通用组件 ─────────────────────────────────────────────────────

  Widget _stepTitle(String title, bool isDark) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: isDark ? Colors.white : Colors.black87,
      ),
    );
  }

  Widget _createOptionTile(
    bool isDark, {
    required bool selected,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? trailingBadge,
  }) {
    final subColor = isDark ? Colors.white60 : Colors.grey[600];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? Theme.of(context).primaryColor
                  : (isDark ? Colors.white12 : Colors.grey[300]!),
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
            color: selected
                ? Theme.of(context).primaryColor.withValues(alpha: 0.06)
                : Colors.transparent,
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 20,
                color: selected
                    ? Theme.of(context).primaryColor
                    : subColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 12, color: subColor),
                    ),
                  ],
                ),
              ),
              if (trailingBadge != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    trailingBadge,
                    style:
                        const TextStyle(fontSize: 10, color: Colors.green),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusChip(CourseEvaluationStatus status, bool isDark) {
    final (label, color) = switch (status) {
      CourseEvaluationStatus.published => ('已发布', Colors.green),
      CourseEvaluationStatus.needsEdit => ('需修改', Colors.orange),
      CourseEvaluationStatus.pending => ('待审核', Colors.blue),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}
