import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../main.dart';
import '../../models/exam_paper.dart';
import '../../providers/auth_provider.dart';
import '../../services/exam_paper_service.dart';
import '../../widgets/exam_paper_access_guide.dart';
import '../../widgets/exam_paper_card.dart';
import '../../widgets/exam_papers/exam_paper_empty_state.dart';
import '../../widgets/exam_papers/exam_paper_list_skeleton.dart';
import '../../widgets/exam_papers/exam_paper_toolbar.dart';
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
  final List<String> _academicYears = [];
  ExamPaperService? _service;
  Timer? _searchDebounce;
  bool _loadScheduled = false;
  bool _loading = false;
  bool _refreshing = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  int _total = 0;
  int _requestGeneration = 0;
  String? _error;
  String _academicYear = '';
  String _semester = '';
  String _examType = '';
  String _sort = 'latest';

  @override
  void initState() {
    super.initState();
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
        _loading = _items.isEmpty;
        _refreshing = true;
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
        _total = result.total;
        _academicYears
          ..clear()
          ..addAll(result.academicYears);
        _hasMore = result.hasMore;
        _loading = false;
        _refreshing = false;
        _loadScheduled = true;
      });
    } on ExamPaperApiException catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _error = error.message;
        _loading = false;
        _refreshing = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final service = _service;
    if (service == null ||
        _loading ||
        _refreshing ||
        _loadingMore ||
        _error != null ||
        !_hasMore) {
      return;
    }
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
        builder: (_) => MyExamPaperSubmissionsScreen(
          service: service,
          isAdmin: context.read<AuthProvider>().user?.isAdmin == true,
        ),
      ),
    );
    if (mounted) await _load(refresh: true);
  }

  Future<void> _openUpload({String initialCourseName = ''}) async {
    final service = _service;
    final user = context.read<AuthProvider>().user;
    if (service == null || user == null) return;
    final result = await Navigator.of(context).push<ExamPaper>(
      MaterialPageRoute(
        builder: (_) => ExamPaperUploadScreen(
          service: service,
          isAdmin: user.isAdmin,
          initialCourseName: initialCourseName,
        ),
      ),
    );
    if (!mounted || result == null) return;
    _showMessage(
      result.isPublished ? '试卷已直接发布' : '投稿成功，等待管理员审核',
    );
    await _load(refresh: true);
  }

  int get _activeFilterCount => [
        _academicYear,
        _semester,
        _examType,
        if (_sort != 'latest') _sort,
      ].where((value) => value.isNotEmpty).length;

  bool get _hasQuery =>
      _searchController.text.trim().isNotEmpty || _activeFilterCount > 0;

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _academicYear = '';
      _semester = '';
      _examType = '';
      _sort = 'latest';
    });
    _load(refresh: true);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {});
    _load(refresh: true);
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
        ExamPaperToolbar(
          searchController: _searchController,
          onSearchChanged: (value) {
            setState(() {});
            _onSearchChanged(value);
          },
          academicYear: _academicYear,
          semester: _semester,
          examType: _examType,
          sort: _sort,
          academicYears: _academicYears,
          total: _total,
          activeFilterCount: _activeFilterCount,
          onClearSearch: _clearSearch,
          onClearFilters: _clearFilters,
          onAcademicYearChanged: (value) {
            setState(() => _academicYear = value);
            _load(refresh: true);
          },
          onSemesterChanged: (value) {
            setState(() => _semester = value);
            _load(refresh: true);
          },
          onExamTypeChanged: (value) {
            setState(() => _examType = value);
            _load(refresh: true);
          },
          onSortChanged: (value) {
            setState(() => _sort = value);
            _load(refresh: true);
          },
        ),
        Expanded(child: _buildResults()),
      ],
    );
  }

  Widget _buildResults() {
    if (_loading) return const ExamPaperListSkeleton();
    if (_error != null && _items.isEmpty) {
      return ExamPaperEmptyState(
        icon: Icons.cloud_off_outlined,
        title: '试卷加载失败',
        message: _error!,
        primaryActionLabel: '重试',
        onPrimaryAction: () => _load(refresh: true),
      );
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: 430,
              child: ExamPaperEmptyState(
                icon: Icons.library_books_outlined,
                title: _hasQuery ? '没有找到匹配的试卷' : '还没有试卷',
                message: _hasQuery ? '可以清除当前条件，或投稿这门课的试卷。' : '分享历年试卷，帮助更多同学复习。',
                primaryActionLabel: _hasQuery ? '清除筛选' : '投稿第一份试卷',
                onPrimaryAction: _hasQuery ? _clearFilters : _openUpload,
                secondaryActionLabel: _hasQuery ? '投稿这门课试卷' : null,
                onSecondaryAction: _hasQuery
                    ? () => _openUpload(
                          initialCourseName: _searchController.text.trim(),
                        )
                    : null,
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        if (_error != null)
          MaterialBanner(
            content: Text(_error!),
            leading: const Icon(Icons.cloud_off_outlined),
            actions: [
              TextButton(
                onPressed: () => _load(refresh: true),
                child: const Text('重试'),
              ),
            ],
          ),
        Expanded(
          child: RefreshIndicator(
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
                return ExamPaperCard(
                  paper: paper,
                  showStatus: false,
                  onTap: () => _openDetail(paper),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
