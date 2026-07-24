import 'package:flutter/material.dart';

import '../../app_bootstrap.dart';
import '../../models/exam_paper.dart';
import '../../services/exam_paper_service.dart';
import '../../widgets/glass_container.dart';
import 'exam_paper_preview_screen.dart';

class ExamPaperAdminEditorScreen extends StatefulWidget {
  final ExamPaper paper;
  final ExamPaperService service;

  const ExamPaperAdminEditorScreen({
    super.key,
    required this.paper,
    required this.service,
  });

  @override
  State<ExamPaperAdminEditorScreen> createState() =>
      _ExamPaperAdminEditorScreenState();
}

class _ExamPaperAdminEditorScreenState
    extends State<ExamPaperAdminEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _courseController;
  final _reasonController = TextEditingController();
  late final List<String> _years;
  late String _year;
  late String _semester;
  late String _examType;
  bool _submitting = false;

  bool get _isPending => widget.paper.isPending;

  @override
  void initState() {
    super.initState();
    _courseController = TextEditingController(text: widget.paper.courseName);
    _years = ExamPaperMetadata.academicYears(DateTime.now());
    if (!_years.contains(widget.paper.academicYear)) {
      _years.insert(0, widget.paper.academicYear);
    }
    _year = widget.paper.academicYear;
    _semester = widget.paper.semester;
    _examType = widget.paper.examType;
  }

  @override
  void dispose() {
    _courseController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExamPaperPreviewScreen(
          paper: widget.paper,
          service: widget.service,
        ),
      ),
    );
  }

  Future<void> _approve() async {
    if (!_formKey.currentState!.validate() || _submitting) return;
    await _run(() async {
      await widget.service.approve(
        id: widget.paper.id,
        courseName: _courseController.text,
        academicYear: _year,
        semester: _semester,
        examType: _examType,
        reason: _reasonController.text,
      );
    });
  }

  Future<void> _reject() async {
    if (_submitting) return;
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      _showMessage('拒绝理由不能为空');
      return;
    }
    final confirmed = await _confirm('确认拒绝并删除该投稿吗？');
    if (confirmed != true) return;
    await _run(
        () => widget.service.reject(id: widget.paper.id, reason: reason));
  }

  Future<void> _savePublished() async {
    if (!_formKey.currentState!.validate() || _submitting) return;
    await _run(() async {
      await widget.service.updatePublished(
        id: widget.paper.id,
        courseName: _courseController.text,
        academicYear: _year,
        semester: _semester,
        examType: _examType,
      );
    });
  }

  Future<void> _unpublish() async {
    if (_submitting) return;
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      _showMessage('下架理由不能为空');
      return;
    }
    final confirmed = await _confirm('确认下架并删除该 PDF 吗？经验不会追回�?);
    if (confirmed != true) return;
    await _run(
      () => widget.service.unpublish(id: widget.paper.id, reason: reason),
    );
  }

  Future<bool?> _confirm(String content) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('请确�?),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _submitting = true);
    try {
      await action();
      if (mounted) Navigator.of(context).pop(true);
    } on ExamPaperApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) _showMessage('操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final previewTitle = ExamPaperMetadata.buildTitle(
      courseName: _courseController.text,
      academicYear: _year,
      semester: _semester,
      examType: _examType,
    );
    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(_isPending ? '审核试卷' : '管理已发布试�?),
          backgroundColor: Colors.transparent,
          actions: [
            IconButton(
              tooltip: '预览 PDF',
              onPressed: _preview,
              icon: const Icon(Icons.visibility_outlined),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              GlassContainer(
                padding: const EdgeInsets.all(18),
                borderRadius: 22,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _courseController,
                      maxLength: 100,
                      decoration: const InputDecoration(labelText: '课程�?),
                      onChanged: (_) => setState(() {}),
                      validator: (value) =>
                          (value?.trim().isEmpty ?? true) ? '课程名不能为�? : null,
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: _year,
                      decoration: const InputDecoration(labelText: '学年'),
                      items: _years
                          .map((year) =>
                              DropdownMenuItem(value: year, child: Text(year)))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) setState(() => _year = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _semester,
                            decoration: const InputDecoration(labelText: '学期'),
                            items: ExamPaperMetadata.semesterLabels.entries
                                .map(
                                  (entry) => DropdownMenuItem(
                                    value: entry.key,
                                    child: Text(entry.value),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _semester = value);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            initialValue: _examType,
                            decoration:
                                const InputDecoration(labelText: '考试类型'),
                            items: ExamPaperMetadata.examTypeLabels.entries
                                .map(
                                  (entry) => DropdownMenuItem(
                                    value: entry.key,
                                    child: Text(entry.value),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value != null) {
                                setState(() => _examType = value);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '标题预览\n$previewTitle',
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, height: 1.5),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              GlassContainer(
                padding: const EdgeInsets.all(18),
                borderRadius: 22,
                child: TextField(
                  controller: _reasonController,
                  maxLength: 500,
                  maxLines: 4,
                  decoration: InputDecoration(
                    labelText: _isPending ? '审核理由（通过可选，拒绝必填�? : '下架理由（下架时必填�?,
                    alignLabelWithHint: true,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (_submitting)
                const Center(child: CircularProgressIndicator())
              else if (_isPending)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _reject,
                        icon: const Icon(Icons.close, color: Colors.redAccent),
                        label: const Text('拒绝'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _approve,
                        icon: const Icon(Icons.check),
                        label: const Text('通过并奖�?),
                      ),
                    ),
                  ],
                )
              else
                Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _savePublished,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('保存元数�?),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _unpublish,
                        icon: const Icon(Icons.archive_outlined,
                            color: Colors.redAccent),
                        label: const Text('填写理由后下�?),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
