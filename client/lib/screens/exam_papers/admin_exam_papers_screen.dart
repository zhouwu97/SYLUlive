import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../main.dart';
import '../../models/exam_paper.dart';
import '../../providers/auth_provider.dart';
import '../../services/exam_paper_service.dart';
import '../../widgets/exam_paper_card.dart';
import 'exam_paper_admin_editor_screen.dart';
import 'exam_paper_preview_screen.dart';

class AdminExamPapersScreen extends StatefulWidget {
  const AdminExamPapersScreen({super.key});

  @override
  State<AdminExamPapersScreen> createState() => _AdminExamPapersScreenState();
}

class _AdminExamPapersScreenState extends State<AdminExamPapersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late ExamPaperService _service;
  bool _initialized = false;
  final List<ExamPaper> _pending = [];
  final List<ExamPaper> _published = [];
  bool _loadingPending = true;
  bool _loadingPublished = true;
  String? _pendingError;
  String? _publishedError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _service = ExamPaperService(context.read<AuthProvider>().dio);
    _loadPending();
    _loadPublished();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadPending() async {
    setState(() {
      _loadingPending = true;
      _pendingError = null;
    });
    try {
      final result =
          await _service.adminListAll(status: 'pending', pageSize: 50);
      if (!mounted) return;
      setState(() {
        _pending
          ..clear()
          ..addAll(result);
        _loadingPending = false;
      });
    } on ExamPaperApiException catch (error) {
      if (mounted) {
        setState(() {
          _pendingError = error.message;
          _loadingPending = false;
        });
      }
    }
  }

  Future<void> _loadPublished() async {
    setState(() {
      _loadingPublished = true;
      _publishedError = null;
    });
    try {
      final result =
          await _service.adminListAll(status: 'published', pageSize: 50);
      if (!mounted) return;
      setState(() {
        _published
          ..clear()
          ..addAll(result);
        _loadingPublished = false;
      });
    } on ExamPaperApiException catch (error) {
      if (mounted) {
        setState(() {
          _publishedError = error.message;
          _loadingPublished = false;
        });
      }
    }
  }

  Future<void> _openEditor(ExamPaper paper) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ExamPaperAdminEditorScreen(
          paper: paper,
          service: _service,
        ),
      ),
    );
    if (changed == true && mounted) {
      await Future.wait([_loadPending(), _loadPublished()]);
    }
  }

  Future<void> _preview(ExamPaper paper) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExamPaperPreviewScreen(paper: paper, service: _service),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('试卷审核与管理'),
          backgroundColor: Colors.transparent,
          bottom: TabBar(
            controller: _tabController,
            tabs: [
              Tab(text: '待审核 (${_pending.length})'),
              Tab(text: '已发布 (${_published.length})'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildList(
              items: _pending,
              loading: _loadingPending,
              error: _pendingError,
              onRefresh: _loadPending,
              emptyText: '暂无待审核试卷',
            ),
            _buildList(
              items: _published,
              loading: _loadingPublished,
              error: _publishedError,
              onRefresh: _loadPublished,
              emptyText: '暂无已发布试卷',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList({
    required List<ExamPaper> items,
    required bool loading,
    required String? error,
    required Future<void> Function() onRefresh,
    required String emptyText,
  }) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRefresh, child: const Text('重试')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        itemCount: items.isEmpty ? 1 : items.length,
        itemBuilder: (context, index) {
          if (items.isEmpty) {
            return Padding(
              padding: const EdgeInsets.only(top: 160),
              child: Center(child: Text(emptyText)),
            );
          }
          final paper = items[index];
          return ExamPaperCard(
            paper: paper,
            onTap: () => _openEditor(paper),
            trailing: PopupMenuButton<String>(
              tooltip: '操作',
              onSelected: (value) {
                if (value == 'preview') {
                  _preview(paper);
                } else {
                  _openEditor(paper);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'preview', child: Text('预览 PDF')),
                PopupMenuItem(
                  value: 'edit',
                  child: Text(paper.isPending ? '审核投稿' : '编辑 / 下架'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
