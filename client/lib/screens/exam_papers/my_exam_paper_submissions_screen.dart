import 'package:flutter/material.dart';

import '../../app_bootstrap.dart';
import '../../models/exam_paper.dart';
import '../../services/exam_paper_service.dart';
import '../../widgets/exam_paper_card.dart';
import '../../widgets/exam_papers/exam_paper_empty_state.dart';
import '../../widgets/exam_papers/exam_paper_list_skeleton.dart';
import 'exam_paper_detail_screen.dart';
import 'exam_paper_preview_screen.dart';
import 'exam_paper_upload_screen.dart';

class MyExamPaperSubmissionsScreen extends StatefulWidget {
  final ExamPaperService service;
  final bool isAdmin;

  const MyExamPaperSubmissionsScreen({
    super.key,
    required this.service,
    this.isAdmin = false,
  });

  @override
  State<MyExamPaperSubmissionsScreen> createState() =>
      _MyExamPaperSubmissionsScreenState();
}

class _MyExamPaperSubmissionsScreenState
    extends State<MyExamPaperSubmissionsScreen> {
  final _scrollController = ScrollController();
  final List<ExamPaper> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String? _error;
  String _status = 'all';
  Map<String, int> _statusCounts = const {};
  int _requestGeneration = 0;
  final Set<int> _deleting = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load(refresh: true);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 240) {
      _loadMore();
    }
  }

  Future<void> _load({required bool refresh}) async {
    final generation = ++_requestGeneration;
    if (refresh) {
      setState(() {
        _loading = _items.isEmpty;
        _loadingMore = false;
        _error = null;
        _page = 1;
      });
    }
    try {
      final result = await widget.service.mySubmissions(
        status: _status,
        page: 1,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _items
          ..clear()
          ..addAll(result.items);
        _hasMore = result.hasMore;
        _page = result.page;
        _statusCounts = result.statusCounts;
        _loading = false;
      });
    } on ExamPaperApiException catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final generation = _requestGeneration;
    final status = _status;
    final nextPage = _page + 1;
    setState(() => _loadingMore = true);
    try {
      final result = await widget.service.mySubmissions(
        status: status,
        page: nextPage,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _items.addAll(result.items);
        _page = result.page;
        _hasMore = result.hasMore;
      });
    } on ExamPaperApiException catch (error) {
      if (mounted && generation == _requestGeneration) {
        _showMessage(error.message);
      }
    } catch (_) {
      if (mounted && generation == _requestGeneration) {
        _showMessage('加载更多失败，请稍后重试');
      }
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _withdraw(ExamPaper paper) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤回投稿'),
        content: Text('确认撤回�?{paper.title}》吗？撤回后文件会被删除�?),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认撤回'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.service.withdraw(paper.id);
      if (!mounted) return;
      _showMessage('投稿已撤�?);
      await _load(refresh: true);
    } on ExamPaperApiException catch (error) {
      if (mounted) _showMessage(error.message);
    }
  }

  Future<void> _delete(ExamPaper paper) async {
    if (_deleting.contains(paper.id)) return;
    setState(() => _deleting.add(paper.id));
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('永久删除投稿'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('确认永久删除�?{paper.title}》吗？此操作不可恢复�?),
              if (paper.rewardRevocable) ...[
                const SizedBox(height: 12),
                Text(
                  '删除后将扣回本次投稿奖励�?10 经验�?,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('永久删除'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      final result = await widget.service.deleteSubmission(paper.id);
      if (!mounted) return;
      _showMessage(
        result.expRevoked ? '投稿已永久删除，已扣�?10 经验' : '投稿已永久删�?,
      );
      await _load(refresh: true);
    } on ExamPaperApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() => _deleting.remove(paper.id));
      } else {
        _deleting.remove(paper.id);
      }
    }
  }

  Future<void> _open(ExamPaper paper) async {
    if (paper.isPending) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ExamPaperPreviewScreen(
            paper: paper,
            service: widget.service,
          ),
        ),
      );
      return;
    }
    if (paper.isUnpublished) {
      await _openUpload(paper);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExamPaperDetailScreen(
          paper: paper,
          service: widget.service,
        ),
      ),
    );
  }

  Future<void> _openUpload([ExamPaper? paper]) async {
    final result = await Navigator.of(context).push<ExamPaper>(
      MaterialPageRoute(
        builder: (_) => ExamPaperUploadScreen(
          service: widget.service,
          isAdmin: widget.isAdmin,
          initialCourseName: paper?.courseName ?? '',
          initialAcademicYear: paper?.academicYear,
          initialSemester: paper?.semester,
          initialExamType: paper?.examType,
        ),
      ),
    );
    if (result != null && mounted) await _load(refresh: true);
  }

  Future<void> _changeStatus(String status) async {
    if (_status == status) return;
    setState(() {
      _status = status;
      _items.clear();
      _page = 1;
      _hasMore = false;
    });
    await _load(refresh: true);
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
          title: const Text('\u6211\u7684\u6295\u7a3f'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: Column(
          children: [
            _buildStatusFilter(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const ExamPaperListSkeleton();
    if (_error != null) {
      return ExamPaperEmptyState(
        icon: Icons.cloud_off_outlined,
        title: '投稿记录加载失败',
        message: _error!,
        primaryActionLabel: '重试',
        onPrimaryAction: () => _load(refresh: true),
      );
    }
    if (_items.isEmpty) {
      final filtered = _status != 'all';
      return RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 430,
              child: ExamPaperEmptyState(
                icon: Icons.upload_file_outlined,
                title: filtered ? '该状态下没有投稿' : '还没有试卷投�?,
                message: filtered ? '可以切换其他状态查看投稿记录�? : '投稿通过管理员审核后会收录到试卷库�?,
                primaryActionLabel: filtered ? null : '去投�?,
                onPrimaryAction: filtered ? null : _openUpload,
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(18),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final paper = _items[index];
          return ExamPaperCard(
            paper: paper,
            onTap: () => _open(paper),
            footer: _buildPaperFooter(paper),
          );
        },
      ),
    );
  }

  Widget _buildStatusFilter() {
    const statuses = [
      ('all', '全部'),
      ('pending', '待审�?),
      ('published', '已通过'),
      ('unpublished', '已下�?),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          for (final item in statuses)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                selected: _status == item.$1,
                onSelected: (_) => _changeStatus(item.$1),
                label: Text('${item.$2} ${_statusCounts[item.$1] ?? 0}'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPaperFooter(ExamPaper paper) {
    final theme = Theme.of(context);
    if (paper.isPending) {
      return Row(
        children: [
          Icon(Icons.schedule, size: 16, color: Colors.orange.shade700),
          const SizedBox(width: 6),
          const Expanded(child: Text('管理员审核中')),
          TextButton(
            onPressed: () => _open(paper),
            child: const Text('预览'),
          ),
          TextButton(
            onPressed: () => _withdraw(paper),
            style:
                TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
            child: const Text('撤回'),
          ),
        ],
      );
    }
    if (paper.isPublished) {
      return Row(
        children: [
          Icon(Icons.check_circle_outline,
              size: 16, color: Colors.green.shade700),
          const SizedBox(width: 6),
          const Expanded(child: Text('已收录至试卷�?)),
          TextButton.icon(
            onPressed:
                _deleting.contains(paper.id) ? null : () => _delete(paper),
            style:
                TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('删除'),
          ),
        ],
      );
    }
    final reason = paper.unpublishReason.trim().isEmpty
        ? '未提供下架原�?
        : paper.unpublishReason.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '原因�?reason',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () => _openUpload(paper),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新投稿'),
              ),
              TextButton.icon(
                onPressed:
                    _deleting.contains(paper.id) ? null : () => _delete(paper),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
