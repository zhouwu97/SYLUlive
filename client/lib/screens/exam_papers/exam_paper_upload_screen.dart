import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/exam_paper.dart';
import '../../services/exam_paper_service.dart';
import '../../widgets/glass_container.dart';
import '../../widgets/exam_papers/exam_paper_upload_step_header.dart';

class ExamPaperUploadScreen extends StatefulWidget {
  final ExamPaperService service;
  final bool isAdmin;
  final Future<PlatformFile?> Function()? pickFile;
  final String initialCourseName;
  final String? initialAcademicYear;
  final String? initialSemester;
  final String? initialExamType;

  const ExamPaperUploadScreen({
    super.key,
    required this.service,
    required this.isAdmin,
    this.pickFile,
    this.initialCourseName = '',
    this.initialAcademicYear,
    this.initialSemester,
    this.initialExamType,
  });

  @override
  State<ExamPaperUploadScreen> createState() => _ExamPaperUploadScreenState();
}

class _ExamPaperUploadScreenState extends State<ExamPaperUploadScreen> {
  final _formKey = GlobalKey<FormState>();
  final _courseController = TextEditingController();
  late final List<String> _academicYears;
  late String _academicYear;
  String _semester = 'first';
  String _examType = 'final';
  PlatformFile? _file;
  bool _privacyConfirmed = false;
  bool _uploading = false;
  double _progress = 0;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _academicYears = ExamPaperMetadata.academicYears(DateTime.now());
    _courseController.text = widget.initialCourseName;
    _academicYear = _academicYears.contains(widget.initialAcademicYear)
        ? widget.initialAcademicYear!
        : _academicYears.first;
    if (ExamPaperMetadata.semesterLabels.containsKey(widget.initialSemester)) {
      _semester = widget.initialSemester!;
    }
    if (ExamPaperMetadata.examTypeLabels.containsKey(widget.initialExamType)) {
      _examType = widget.initialExamType!;
    }
    _courseController.addListener(_refreshPreview);
  }

  @override
  void dispose() {
    _courseController
      ..removeListener(_refreshPreview)
      ..dispose();
    super.dispose();
  }

  void _refreshPreview() {
    if (mounted) setState(() {});
  }

  Future<void> _pickFile() async {
    final file = widget.pickFile != null
        ? await widget.pickFile!()
        : (await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: const ['pdf'],
            allowMultiple: false,
            withData: false,
          ))
            ?.files
            .singleOrNull;
    if (file == null) return;
    if (file.extension?.toLowerCase() != 'pdf') {
      _showMessage('请选择 PDF 文件');
      return;
    }
    if (file.size > ExamPaperService.maxFileSize) {
      _showMessage('PDF 不能超过 20 MiB');
      return;
    }
    setState(() {
      _file = file;
      _submitError = null;
    });
  }

  bool get _canSubmit =>
      !_uploading &&
      _courseController.text.trim().isNotEmpty &&
      _file != null &&
      _privacyConfirmed;

  Future<void> _submit() async {
    if (_uploading || !_formKey.currentState!.validate()) return;
    if (_file == null) {
      _showMessage('请先选择 PDF 文件');
      return;
    }
    if (!_privacyConfirmed) {
      _showMessage('请确认文件不含隐私信息且拥有分享权限');
      return;
    }

    setState(() {
      _uploading = true;
      _progress = 0;
      _submitError = null;
    });
    try {
      final paper = await widget.service.upload(
        file: _file!,
        courseName: _courseController.text,
        academicYear: _academicYear,
        semester: _semester,
        examType: _examType,
        privacyConfirmed: _privacyConfirmed,
        onSendProgress: (sent, total) {
          if (mounted && total > 0) setState(() => _progress = sent / total);
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop(paper);
    } on ExamPaperApiException catch (error) {
      if (mounted) setState(() => _submitError = error.message);
    } catch (_) {
      if (mounted) setState(() => _submitError = '上传失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final titlePreview = ExamPaperMetadata.buildTitle(
      courseName:
          _courseController.text.isEmpty ? '课程名' : _courseController.text,
      academicYear: _academicYear,
      semester: _semester,
      examType: _examType,
    );

    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('投稿试卷'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: _canSubmit ? _submit : null,
              icon: _uploading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              label: Text(_uploading ? '上传中…' : '确认投稿'),
            ),
          ),
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              ExamPaperUploadStepHeader(
                infoCompleted: _courseController.text.trim().isNotEmpty,
                fileCompleted: _file != null,
                privacyCompleted: _privacyConfirmed,
                submitting: _uploading,
              ),
              const SizedBox(height: 14),
              GlassContainer(
                padding: const EdgeInsets.all(16),
                borderRadius: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.isAdmin
                          ? '管理员上传后将直接发布，且不奖励经验。'
                          : '投稿将等待管理员审核，通过后奖励 10 经验。',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _courseController,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: '课程名',
                        hintText: '例如：高等数学',
                        prefixIcon: Icon(Icons.menu_book_outlined),
                      ),
                      validator: (value) {
                        final text = value?.trim() ?? '';
                        if (text.isEmpty) return '请输入课程名';
                        if (text.runes.length > 100) return '课程名不能超过100个字符';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _academicYear,
                      decoration: const InputDecoration(
                        labelText: '学年',
                        prefixIcon: Icon(Icons.calendar_today_outlined),
                      ),
                      items: [
                        for (final year in _academicYears)
                          DropdownMenuItem(value: year, child: Text(year)),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _academicYear = value);
                        }
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
                    const SizedBox(height: 14),
                    Text('标题预览', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 6),
                    Text(
                      titlePreview,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              GlassContainer(
                padding: const EdgeInsets.all(16),
                borderRadius: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.picture_as_pdf_outlined),
                        title: Text(_file?.name ?? '选择 PDF 文件'),
                        subtitle: _file == null
                            ? const Text('仅支持 PDF，最大 20 MiB')
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${(_file!.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                                  ),
                                  Text(
                                    '校验通过',
                                    style: TextStyle(
                                      color: Colors.green.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                        trailing: OutlinedButton(
                          onPressed: _uploading ? null : _pickFile,
                          child: Text(_file == null ? '选择' : '更换'),
                        ),
                      ),
                    ),
                    Material(
                      color: Colors.transparent,
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _privacyConfirmed,
                        onChanged: _uploading
                            ? null
                            : (value) => setState(
                                  () => _privacyConfirmed = value ?? false,
                                ),
                        title: const Text('我确认文件不含个人隐私信息，并拥有分享权限'),
                        subtitle: const Text('投稿内容将由管理员复核。'),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                    ),
                    if (_uploading) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                          value: _progress == 0 ? null : _progress),
                      const SizedBox(height: 6),
                      Text(
                          '正在安全校验并上传 ${(100 * _progress).toStringAsFixed(0)}%'),
                    ],
                  ],
                ),
              ),
              if (_submitError != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .errorContainer
                        .withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_submitError!)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
