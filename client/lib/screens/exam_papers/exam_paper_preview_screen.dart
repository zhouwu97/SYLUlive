import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../models/exam_paper.dart';
import '../../services/exam_paper_service.dart';

class ExamPaperPreviewScreen extends StatefulWidget {
  final ExamPaper paper;
  final ExamPaperService service;

  const ExamPaperPreviewScreen({
    super.key,
    required this.paper,
    required this.service,
  });

  @override
  State<ExamPaperPreviewScreen> createState() => _ExamPaperPreviewScreenState();
}

class _ExamPaperPreviewScreenState extends State<ExamPaperPreviewScreen> {
  File? _file;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final file = await widget.service.downloadPreview(widget.paper);
      if (!mounted) {
        await file.delete().catchError((_) => file);
        return;
      }
      final previous = _file;
      setState(() {
        _file = file;
        _loading = false;
      });
      if (previous != null && previous.path != file.path) {
        await previous.delete().catchError((_) => previous);
      }
    } on ExamPaperApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'PDF 预览加载失败';
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    final file = _file;
    if (file != null) {
      Future<void>(() async {
        await file.delete().catchError((_) => file);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.paper.title)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.picture_as_pdf_outlined, size: 52),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loading ? null : _load,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading || _file == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            Text('正在准备安全预览�?),
          ],
        ),
      );
    }
    return PdfViewer.file(_file!.path);
  }
}
