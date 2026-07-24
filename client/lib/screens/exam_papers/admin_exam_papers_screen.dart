import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_bootstrap.dart';
import '../../models/exam_paper.dart';
import '../../providers/auth_provider.dart';
import '../../services/exam_paper_service.dart';
import '../../widgets/exam_paper_card.dart';
import '../../widgets/exam_papers/exam_paper_empty_state.dart';
import '../../widgets/exam_papers/exam_paper_list_skeleton.dart';
import 'exam_paper_admin_editor_screen.dart';
import 'exam_paper_preview_screen.dart';

class AdminExamPapersScreen extends StatefulWidget {
  final ExamPaperService? service;

  const AdminExamPapersScreen({super.key, this.service});

  @override
  State<AdminExamPapersScreen> createState() => _AdminExamPapersScreenState();
}

class _AdminExamPapersScreenState extends State<AdminExamPapersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late ExamPaperService _service;
  final _keywordController = TextEditingController();
  final _contributorController = TextEditingController();
  Timer? _searchDebounce;
  bool _initialized = false;
  final List<ExamPaper> _pending = [];
  final List<ExamPaper> _published = [];
  final Set<int> _approving = {};
  bool _loadingPending = true;
  bool _loadingPublished = true;
  String? _pendingError;
  String? _publishedError;
  String _sort = 'oldest';
  int _requestGeneration = 0;

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
    _service =
        widget.service ?? ExamPaperService(context.read<AuthProvider>().dio);
    _loadAll();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchDebounce?.cancel();
    _keywordController.dispose();
    _contributorController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final generation = ++_requestGeneration;
    await Future.wait([
      _loadPending(generation),
      _loadPublished(generation),
    ]);
  }

  Future<void> _loadPending(int generation) async {
    setState(() {
      _loadingPending = _pending.isEmpty;
      _pendingError = null;
    });
    try {
      final result = await _service.adminListAll(
        status: 'pending',
        keyword: _keywordController.text,
        contributor: _contributorController.text,
        sort: _sort,
        pageSize: 50,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _pending
          ..clear()
          ..addAll(result);
        _loadingPending = false;
      });
    } on ExamPaperApiException catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _pendingError = error.message;
        _loadingPending = false;
      });
    }
  }

  Future<void> _loadPublished(int generation) async {
    setState(() {
      _loadingPublished = _published.isEmpty;
      _publishedError = null;
    });
    try {
      final result = await _service.adminListAll(
        status: 'published',
        keyword: _keywordController.text,
        contributor: _contributorController.text,
        sort: _sort,
        pageSize: 50,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _published
          ..clear()
          ..addAll(result);
        _loadingPublished = false;
      });
    } on ExamPaperApiException catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _publishedError = error.message;
        _loadingPublished = false;
      });
    }
  }

  void _onFilterChanged([String? _]) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 420), () {
      if (mounted) _loadAll();
    });
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
    if (changed == true && mounted) await _loadAll();
  }

  Future<void> _preview(ExamPaper paper) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExamPaperPreviewScreen(paper: paper, service: _service),
      ),
    );
  }

  Future<void> _quickApprove(ExamPaper paper) async {
    if (_approving.contains(paper.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认通过该试卷？'),
        content: Text('将按当前元数据发布：\n${paper.title}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认通过'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _approving.add(paper.id));
    try {
      await _service.approve(
        id: paper.id,
        courseName: paper.courseName,
        academicYear: paper.academicYear,
        semester: paper.semester,
        examType: paper.examType,
        reason: '快捷审核通过',
      );
      if (mounted) await _loadAll();
    } on ExamPaperApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _approving.remove(paper.id));
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
        body: Column(
          children: [
            _buildToolbar(),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildList(
                    items: _pending,
                    loading: _loadingPending,
                    error: _pendingError,
                    onRefresh: _loadAll,
                    pending: true,
                  ),
                  _buildList(
                    items: _published,
                    loading: _loadingPublished,
                    error: _publishedError,
                    onRefresh: _loadAll,
                    pending: false,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('admin-paper-keyword'),
                  controller: _keywordController,
                  onChanged: _onFilterChanged,
                  decoration: const InputDecoration(
                    hintText: '搜索课程',
                    prefixIcon: Icon(Icons.search, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey('admin-paper-contributor'),
                  controller: _contributorController,
                  onChanged: _onFilterChanged,
                  decoration: const InputDecoration(
                    hintText: '搜索投稿人',
                    prefixIcon: Icon(Icons.person_search_outlined, size: 20),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: DropdownButton<String>(
              value: _sort,
              borderRadius: BorderRadius.circular(10),
              items: const [
                DropdownMenuItem(value: 'oldest', child: Text('最早提交')),
                DropdownMenuItem(value: 'latest', child: Text('最新提交')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _sort = value);
                _onFilterChanged();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList({
    required List<ExamPaper> items,
    required bool loading,
    required String? error,
    required Future<void> Function() onRefresh,
    required bool pending,
  }) {
    if (loading) return const ExamPaperListSkeleton();
    if (error != null && items.isEmpty) {
      return ExamPaperEmptyState(
        icon: Icons.cloud_off_outlined,
        title: '管理列表加载失败',
        message: error,
        primaryActionLabel: '重试',
        onPrimaryAction: onRefresh,
      );
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 420,
              child: ExamPaperEmptyState(
                icon: pending
                    ? Icons.task_alt_outlined
                    : Icons.library_books_outlined,
                title: pending ? '当前没有待处理投稿' : '暂无已发布试卷',
                message: pending ? '新的投稿会显示在这里。' : '发布后的试卷会显示在这里。',
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        if (error != null)
          MaterialBanner(
            content: Text(error),
            actions: [
              TextButton(onPressed: onRefresh, child: const Text('重试')),
            ],
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final paper = items[index];
                return ExamPaperCard(
                  paper: paper,
                  onTap: () => _openEditor(paper),
                  footer: _buildPaperActions(paper),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPaperActions(ExamPaper paper) {
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(44, 40),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    );
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        spacing: 4,
        children: [
          TextButton.icon(
            style: buttonStyle,
            onPressed: () => _preview(paper),
            icon: const Icon(Icons.visibility_outlined, size: 18),
            label: const Text('预览'),
          ),
          TextButton.icon(
            style: buttonStyle,
            onPressed: () => _openEditor(paper),
            icon: Icon(
              paper.isPending
                  ? Icons.rate_review_outlined
                  : Icons.edit_outlined,
              size: 18,
            ),
            label: Text(paper.isPending ? '审核' : '管理'),
          ),
          if (paper.isPending)
            FilledButton.icon(
              onPressed: _approving.contains(paper.id)
                  ? null
                  : () => _quickApprove(paper),
              icon: const Icon(Icons.check, size: 18),
              label: const Text('通过'),
            ),
        ],
      ),
    );
  }
}
