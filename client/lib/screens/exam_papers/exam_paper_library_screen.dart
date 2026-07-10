import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../main.dart';
import '../../models/exam_paper.dart';
import '../../providers/auth_provider.dart';
import '../../services/exam_paper_service.dart';
import '../../widgets/exam_paper_access_guide.dart';
import '../../widgets/exam_paper_card.dart';
import '../../widgets/glass_container.dart';
import '../edu_screen.dart';
import '../login_screen.dart';
import 'exam_paper_detail_screen.dart';
import 'exam_paper_upload_screen.dart';
import 'my_exam_paper_submissions_screen.dart';

class ExamPaperLibraryScreen extends StatefulWidget {
  final ExamPaperService? service;

  const ExamPaperLibraryScreen({super.key, this.service});

  @override
  State<ExamPaperLibraryScreen> createState() => _ExamPaperLibraryScreenState();
}

class _ExamPaperLibraryScreenState extends State<ExamPaperLibraryScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final List<ExamPaper> _items = [];
  late final List<String> _academicYears;
  ExamPaperService? _service;
  Timer? _searchDebounce;
  bool _loadScheduled = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  int _requestGeneration = 0;
  String? _error;
  String _academicYear = '';
  String _semester = '';
  String _examType = '';
  String _sort = 'latest';

  @override
  void initState() {
    super.initState();
    _academicYears = ExamPaperMetadata.academicYears(DateTime.now());
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = context.watch<AuthProvider>();
    _service ??= widget.service ?? ExamPaperService(auth.dio);
    final canAccess = auth.isLoggedIn &&
        (auth.user?.isAdmin == true || auth.user?.eduBound == true);
    if (canAccess && !_loadScheduled && _items.isEmpty && !_loading) {
      _loadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(refresh: true);
      });
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 260) {
      _loadMore();
    }
  }

  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 420), () {
      if (mounted) _load(refresh: true);
    });
  }

  Future<void> _load({required bool refresh}) async {
    final service = _service;
    if (service == null) return;
    final generation = ++_requestGeneration;
    final keyword = _searchController.text;
    final academicYear = _academicYear;
    final semester = _semester;
    final examType = _examType;
    final sort = _sort;
    if (refresh) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
      });
    }
    try {
      final result = await service.list(
        keyword: keyword,
        academicYear: academicYear,
        semester: semester,
        examType: examType,
        sort: sort,
        page: 1,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _items
          ..clear()
          ..addAll(result.items);
        _page = result.page;
        _hasMore = result.hasMore;
        _loading = false;
        _loadScheduled = true;
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
    final service = _service;
    if (service == null || _loading || _loadingMore || !_hasMore) return;
    final generation = _requestGeneration;
    final nextPage = _page + 1;
    final keyword = _searchController.text;
    final academicYear = _academicYear;
    final semester = _semester;
    final examType = _examType;
    final sort = _sort;
    setState(() => _loadingMore = true);
    try {
      final result = await service.list(
        keyword: keyword,
        academicYear: academicYear,
        semester: semester,
        examType: examType,
        sort: sort,
        page: nextPage,
      );
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _items.addAll(result.items);
        _page = result.page;
        _hasMore = result.hasMore;
      });
    } on ExamPaperApiException catch (error) {
      if (mounted) _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _openLogin() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    await auth.refreshUser();
    if (mounted) _loadScheduled = false;
  }

  Future<void> _openEduVerification() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const EduScreen()),
    );
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    await auth.refreshUser();
    if (!mounted) return;
    _loadScheduled = false;
    if (auth.user?.eduBound == true || auth.user?.isAdmin == true) {
      await _load(refresh: true);
    }
  }

  Future<void> _openMySubmissions() async {
    final service = _service;
    if (service == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MyExamPaperSubmissionsScreen(service: service),
      ),
    );
    if (mounted) await _load(refresh: true);
  }

  Future<void> _openUpload() async {
    final service = _service;
    final user = context.read<AuthProvider>().user;
    if (service == null || user == null) return;
    final result = await Navigator.of(context).push<ExamPaper>(
      MaterialPageRoute(
        builder: (_) => ExamPaperUploadScreen(
          service: service,
          isAdmin: user.isAdmin,
        ),
      ),
    );
    if (!mounted || result == null) return;
    _showMessage(
      result.isPublished ? '试卷已直接发布' : '投稿成功，等待管理员审核',
    );
    await _load(refresh: true);
  }

  Future<void> _openDetail(ExamPaper paper) async {
    final service = _service;
    if (service == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExamPaperDetailScreen(paper: paper, service: service),
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
    final auth = context.watch<AuthProvider>();
    final user = auth.user;
    final canAccess =
        auth.isLoggedIn && (user?.isAdmin == true || user?.eduBound == true);

    return GlobalBackgroundWrapper(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('试卷库'),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            if (canAccess)
              IconButton(
                tooltip: '我的投稿',
                onPressed: _openMySubmissions,
                icon: const Icon(Icons.inventory_2_outlined),
              ),
          ],
        ),
        floatingActionButton: canAccess
            ? FloatingActionButton.extended(
                onPressed: _openUpload,
                icon: const Icon(Icons.add),
                label: const Text('投稿'),
              )
            : null,
        body: !auth.isInitialized
            ? const Center(child: CircularProgressIndicator())
            : !auth.isLoggedIn
                ? ExamPaperAccessGuide(
                    type: ExamPaperAccessGuideType.login,
                    onAction: _openLogin,
                  )
                : !canAccess
                    ? ExamPaperAccessGuide(
                        type: ExamPaperAccessGuideType.eduVerification,
                        onAction: _openEduVerification,
                      )
                    : _buildLibrary(),
      ),
    );
  }

  Widget _buildLibrary() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: GlassContainer(
            padding: const EdgeInsets.all(12),
            borderRadius: 20,
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: '搜索课程名',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _searchController.clear();
                              _load(refresh: true);
                            },
                            icon: const Icon(Icons.clear),
                          ),
                    border: InputBorder.none,
                    filled: false,
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterDropdown(
                        value: _academicYear,
                        label: '学年',
                        items: {
                          '': '全部学年',
                          for (final year in _academicYears) year: year,
                        },
                        onChanged: (value) {
                          setState(() => _academicYear = value);
                          _load(refresh: true);
                        },
                      ),
                      _FilterDropdown(
                        value: _semester,
                        label: '学期',
                        items: const {
                          '': '全部学期',
                          ...ExamPaperMetadata.semesterLabels,
                        },
                        onChanged: (value) {
                          setState(() => _semester = value);
                          _load(refresh: true);
                        },
                      ),
                      _FilterDropdown(
                        value: _examType,
                        label: '类型',
                        items: const {
                          '': '全部类型',
                          ...ExamPaperMetadata.examTypeLabels,
                        },
                        onChanged: (value) {
                          setState(() => _examType = value);
                          _load(refresh: true);
                        },
                      ),
                      _FilterDropdown(
                        value: _sort,
                        label: '排序',
                        items: const {'latest': '最新', 'downloads': '下载最多'},
                        onChanged: (value) {
                          setState(() => _sort = value);
                          _load(refresh: true);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: _buildResults()),
      ],
    );
  }

  Widget _buildResults() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 52),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 14),
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
            SizedBox(height: 130),
            Icon(Icons.library_books_outlined, size: 58),
            SizedBox(height: 14),
            Center(child: Text('暂无符合条件的试卷')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(refresh: true),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 100),
        itemCount: _items.length + (_loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return const Padding(
              padding: EdgeInsets.all(18),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final paper = _items[index];
          return ExamPaperCard(paper: paper, onTap: () => _openDetail(paper));
        },
      ),
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  final String value;
  final String label;
  final Map<String, String> items;
  final ValueChanged<String> onChanged;

  const _FilterDropdown({
    required this.value,
    required this.label,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            borderRadius: BorderRadius.circular(14),
            items: items.entries
                .map(
                  (entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.value),
                  ),
                )
                .toList(),
            onChanged: (next) {
              if (next != null) onChanged(next);
            },
          ),
        ),
      ),
    );
  }
}
