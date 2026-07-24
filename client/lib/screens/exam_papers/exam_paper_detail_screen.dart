import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/api_constants.dart';
import '../../app_bootstrap.dart';
import '../../models/exam_paper.dart';
import '../../services/exam_paper_service.dart';
import '../../widgets/cached_avatar.dart';
import '../../widgets/glass_container.dart';
import 'exam_paper_preview_screen.dart';

class ExamPaperDetailScreen extends StatefulWidget {
  final ExamPaper paper;
  final ExamPaperService service;

  const ExamPaperDetailScreen({
    super.key,
    required this.paper,
    required this.service,
  });

  @override
  State<ExamPaperDetailScreen> createState() => _ExamPaperDetailScreenState();
}

class _ExamPaperDetailScreenState extends State<ExamPaperDetailScreen> {
  bool _downloading = false;
  late int _downloadCount;

  @override
  void initState() {
    super.initState();
    _downloadCount = widget.paper.downloadCount;
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

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    File? file;
    try {
      file = await widget.service.downloadForShare(widget.paper);
      if (!mounted) return;
      final renderBox = context.findRenderObject() as RenderBox?;
      final shareOrigin = renderBox == null
          ? null
          : renderBox.localToGlobal(Offset.zero) & renderBox.size;
      await Share.shareXFiles(
        [
          XFile(file.path,
              mimeType: 'application/pdf', name: '${widget.paper.title}.pdf')
        ],
        text: widget.paper.title,
        subject: widget.paper.title,
        sharePositionOrigin: shareOrigin,
      );
      if (mounted) setState(() => _downloadCount += 1);
    } on ExamPaperApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) _showMessage('下载失败，请稍后重试');
    } finally {
      if (file != null) {
        await file.delete().catchError((_) => file!);
      }
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final paper = widget.paper;
    final theme = Theme.of(context);
    final publishedAt =
        paper.publishedAt?.toLocal() ?? paper.createdAt.toLocal();

    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('试卷详情'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            children: [
              GlassContainer(
                padding: const EdgeInsets.all(20),
                borderRadius: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(
                            Icons.picture_as_pdf_outlined,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            paper.title,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _InfoRow(label: '课程', value: paper.courseName),
                    _InfoRow(label: '学年', value: paper.academicYear),
                    _InfoRow(label: '学期', value: paper.semesterLabel),
                    _InfoRow(label: '考试类型', value: paper.examTypeLabel),
                    _InfoRow(label: '文件大小', value: paper.fileSizeLabel),
                    _InfoRow(
                      label: '发布时间',
                      value: DateFormat('yyyy-MM-dd HH:mm').format(publishedAt),
                    ),
                    _InfoRow(label: '下载�?, value: '$_downloadCount'),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              GlassContainer(
                padding: const EdgeInsets.all(16),
                borderRadius: 20,
                child: Row(
                  children: [
                    CachedAvatar(
                      imageUrl: paper.contributor.avatar.isEmpty
                          ? null
                          : ApiConstants.fullUrl(paper.contributor.avatar),
                      fallbackText: paper.contributor.nickname,
                      radius: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            paper.contributor.nickname,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '贡献�?· Lv.${paper.contributor.level}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.verified_outlined, color: Colors.green),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _preview,
                      icon: const Icon(Icons.visibility_outlined),
                      label: const Text('应用内预�?),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _downloading ? null : _download,
                      icon: _downloading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined),
                      label: Text(_downloading ? '下载中�? : '下载 / 分享'),
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

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
