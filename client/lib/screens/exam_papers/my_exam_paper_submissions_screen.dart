import 'package:flutter/material.dart';

import '../../main.dart';
import '../../models/exam_paper.dart';
import '../../services/exam_paper_service.dart';
import '../../widgets/exam_paper_card.dart';
import 'exam_paper_detail_screen.dart';
import 'exam_paper_preview_screen.dart';

class MyExamPaperSubmissionsScreen extends StatefulWidget {
  final ExamPaperService service;

  const MyExamPaperSubmissionsScreen({
    super.key,
    required this.service,
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
    if (refresh) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
      });
    }
    try {
      final result = await widget.service.mySubmissions(page: 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(result.items);
        _hasMore = result.hasMore;
        _page = result.page;
        _loading = false;
      });
    } on ExamPaperApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final result = await widget.service.mySubmissions(page: _page + 1);
      if (!mounted) return;
      setState(() {
        _items.addAll(result.items);
        _page = result.page;
        _hasMore = result.hasMore;
      });
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _withdraw(ExamPaper paper) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤回投稿'),
        content: Text('确认撤回《${paper.title}》吗？撤回后文件会被删除。'),
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
      setState(() {
        _items.removeWhere((item) => item.id == paper.id);
      });
      _showMessage('投稿已撤回');
    } on ExamPaperApiException catch (error) {
      if (mounted) _showMessage(error.message);
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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExamPaperDetailScreen(
          paper: paper,
          service: widget.service,
        ),
      ),
    );
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
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            FilledButton(
                onPressed: () => _load(refresh: true), child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 180),
            Icon(Icons.upload_file_outlined, size: 56),
            SizedBox(height: 14),
            Center(child: Text('还没有试卷投稿')),
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
            trailing: paper.isPending
                ? IconButton(
                    tooltip: '撤回',
                    onPressed: () => _withdraw(paper),
                    icon: const Icon(Icons.delete_outline,
                        color: Colors.redAccent),
                  )
                : null,
          );
        },
      ),
    );
  }
}
