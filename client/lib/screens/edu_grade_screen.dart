import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/edu_provider.dart';
import '../providers/auth_provider.dart';
import '../models/edu_academic_situation.dart';
import '../models/edu_grade.dart';
import '../utils/app_motion.dart';
import '../utils/edu_semester_utils.dart';
import '../widgets/edu_grade/academic_course_item.dart';
import '../widgets/edu_grade/grade_gpa_hero_card.dart';
import '../widgets/edu_grade/grade_summary_card.dart';
import '../widgets/edu_grade/grade_course_item.dart';
import '../widgets/edu_grade/grade_empty_state.dart';
import 'edu_academic_course_detail_screen.dart';
import 'edu_grade_detail_screen.dart';
import '../widgets/edu_grade/grade_manage_drawer.dart';

enum GradeViewMode { academic, term }

class EduGradeScreen extends StatefulWidget {
  const EduGradeScreen({super.key});

  @override
  State<EduGradeScreen> createState() => _EduGradeScreenState();
}

class _EduGradeScreenState extends State<EduGradeScreen> {
  String _selectedYear = '';
  int _selectedSemester = EduSemester.first;
  List<EduGrade> _grades = [];
  GradePageState _pageState = GradePageState.loading;
  // Cache timestamp — currently not rendered in UI, retained for future use
  // ignore: unused_field
  DateTime? _lastUpdatedAt;
  bool _isInitialLoading = false;
  bool _isRefreshing = false;
  int _requestGeneration = 0;
  int _academicRequestGeneration = 0;
  String? _errorMessage;
  String? _lastUserId;
  String _activeFilter = '全部'; // '全部' | '学位课' | '未通过'
  GradeViewMode _viewMode = GradeViewMode.academic;
  EduAcademicSituation? _academicSituation;
  bool _isAcademicLoading = false;
  bool _isAcademicRefreshing = false;
  String? _academicError;
  String _academicFilter = '全部';

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  EduProvider? _eduProvider;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final eduProvider = context.read<EduProvider>();
    final authProvider = context.read<AuthProvider>();
    final currentUserId = authProvider.user?.id.toString();

    if (_eduProvider != eduProvider || _lastUserId != currentUserId) {
      _eduProvider = eduProvider;
      _lastUserId = currentUserId;

      // 立即废弃旧用户的所有进行中请求并清空页面
      _requestGeneration++;
      _academicRequestGeneration++;
      setState(() {
        _grades = [];
        _academicSituation = null;
        _lastUpdatedAt = null;
        _activeFilter = '全部';
        _academicFilter = '全部';
        _viewMode = GradeViewMode.academic;
        _errorMessage = null;
        _academicError = null;
        _pageState = GradePageState.loading;
        _isInitialLoading = true;
        _isRefreshing = false;
        _isAcademicLoading = true;
        _isAcademicRefreshing = false;
      });

      if (currentUserId != null) {
        // 捕获局部变量防止异步期间 _lastUserId 变化
        final capturedUserId = currentUserId;
        eduProvider.setUserId(currentUserId);
        _initSemesterAndLoad(capturedUserId);
      }
    }
  }

  Future<void> _initSemesterAndLoad(String userId) async {
    // Load persisted semester
    final prefs = await SharedPreferences.getInstance();
    final savedKey = 'edu_last_semester_$userId';
    final saved = prefs.getString(savedKey);

    bool loaded = false;
    if (saved != null) {
      final parts = saved.split('_');
      if (parts.length == 2) {
        final year = parts[0];
        final sem = int.tryParse(parts[1]);
        final enrollmentYear = _eduProvider?.enrollmentYear ?? 2000;
        final cur = EduSemester.current();
        final curYear = int.tryParse(cur.year) ?? DateTime.now().year;

        if (sem != null &&
            EduSemester.isValid(sem) &&
            int.tryParse(year) != null &&
            int.parse(year) >= enrollmentYear &&
            (int.parse(year) < curYear ||
                (int.parse(year) == curYear && sem <= cur.semester))) {
          _selectedYear = year;
          _selectedSemester = sem;
          loaded = true;
        }
      }
    }

    if (!loaded) {
      final cur = EduSemester.current();
      _selectedYear = cur.year;
      _selectedSemester = cur.semester;
    }

    if (mounted) setState(() {});
    _loadAcademicSituation();
    _loadGrades();
  }

  Future<void> _loadAcademicSituation({bool forceRefresh = false}) async {
    final provider = _eduProvider;
    if (provider == null) return;

    final cache = provider.getCachedAcademicSituation();
    if (cache != null && !forceRefresh) {
      setState(() {
        _academicSituation = cache.data;
        _isAcademicLoading = false;
        _isAcademicRefreshing = true;
        _academicError = null;
      });
    } else {
      setState(() {
        _isAcademicLoading = _academicSituation == null;
        _isAcademicRefreshing = _academicSituation != null;
        _academicError = null;
      });
    }

    final gen = ++_academicRequestGeneration;
    final result =
        await provider.fetchAcademicSituation(forceRefresh: forceRefresh);

    if (!mounted || _academicRequestGeneration != gen) return;

    if (result.success && result.data != null) {
      setState(() {
        _academicSituation = result.data!;
        _isAcademicLoading = false;
        _isAcademicRefreshing = false;
        _academicError = null;
      });
      return;
    }

    setState(() {
      _isAcademicLoading = false;
      _isAcademicRefreshing = false;
      _academicError = result.errorMessage ?? '官方 GPA 获取失败';
    });
  }

  Future<void> _loadGrades() async {
    if (_eduProvider == null) return;

    final cache =
        _eduProvider!.getCachedGrades(_selectedYear, _selectedSemester);
    if (cache != null) {
      // Cache hit: show immediately, refresh in background
      setState(() {
        _grades = cache.grades;
        _lastUpdatedAt = cache.updatedAt;
        _pageState =
            _grades.isEmpty ? GradePageState.empty : GradePageState.content;
        _isInitialLoading = false;
        _isRefreshing = true;
      });
    } else {
      // Cache miss: full loading state
      setState(() {
        _isInitialLoading = true;
        _isRefreshing = false;
        _pageState = GradePageState.loading;
        _errorMessage = null;
      });
    }

    final gen = ++_requestGeneration;
    final result =
        await _eduProvider!.fetchGrades(_selectedYear, _selectedSemester);

    if (!mounted || _requestGeneration != gen) return;

    if (result.success && result.data != null) {
      final entry =
          _eduProvider!.getCachedGrades(_selectedYear, _selectedSemester);
      setState(() {
        _grades = result.data!;
        _lastUpdatedAt = entry?.updatedAt;
        _pageState = result.data!.isEmpty
            ? GradePageState.empty
            : GradePageState.content;
        _isInitialLoading = false;
        _isRefreshing = false;
        _errorMessage = null;
      });
    } else {
      final errorMsg = result.errorMessage ?? '成绩加载失败';
      if (_grades.isNotEmpty) {
        // Has previous data — keep it
        setState(() {
          _isInitialLoading = false;
          _isRefreshing = false;
        });
        if (mounted) _showSnackBar('刷新失败，请稍后重试');
      } else {
        setState(() {
          _pageState = GradePageState.error;
          _errorMessage = errorMsg;
          _isInitialLoading = false;
          _isRefreshing = false;
        });
      }
    }
  }

  Future<bool> _refreshGrades() async {
    if (_isInitialLoading || _isRefreshing) return false;
    if (_eduProvider == null) return false;

    setState(() => _isRefreshing = true);

    final gen = ++_requestGeneration;
    final result =
        await _eduProvider!.fetchGrades(_selectedYear, _selectedSemester);

    if (!mounted || _requestGeneration != gen) {
      // 页面已切换或用户变化 → 视为失败
      return false;
    }

    if (result.success && result.data != null) {
      final entry =
          _eduProvider!.getCachedGrades(_selectedYear, _selectedSemester);
      setState(() {
        _grades = result.data!;
        _lastUpdatedAt = entry?.updatedAt;
        _pageState = result.data!.isEmpty
            ? GradePageState.empty
            : GradePageState.content;
        _isRefreshing = false;
      });
      if (mounted) _showSnackBar('成绩已更新');
      return true;
    }

    setState(() => _isRefreshing = false);
    if (mounted) _showSnackBar('刷新失败，请稍后重试');
    return false;
  }

  Future<bool> _refreshAcademicSituation() async {
    if (_isAcademicLoading || _isAcademicRefreshing) return false;
    await _loadAcademicSituation(forceRefresh: true);
    final success = _academicError == null && _academicSituation != null;
    if (mounted) _showSnackBar(success ? '学业情况已更新' : '刷新失败，请稍后重试');
    return success;
  }

  Future<bool> _refreshCurrentView() {
    return _viewMode == GradeViewMode.academic
        ? _refreshAcademicSituation()
        : _refreshGrades();
  }

  /// Atomically switch semester — old grades stay visible during load.
  /// Returns true on success, false if failed or stale.
  Future<bool> _switchSemester(String year, int semester) async {
    if (year == _selectedYear && semester == _selectedSemester) {
      return true;
    }

    final provider = _eduProvider;
    if (provider == null) return false;

    final generation = ++_requestGeneration;
    final cache = provider.getCachedGrades(year, semester);

    if (cache != null) {
      if (!mounted || generation != _requestGeneration) return false;

      setState(() {
        _selectedYear = year;
        _selectedSemester = semester;
        _grades = cache.grades;
        _lastUpdatedAt = cache.updatedAt;
        _activeFilter = '全部';
        _pageState = cache.grades.isEmpty
            ? GradePageState.empty
            : GradePageState.content;
      });

      _saveSelectedSemester(year, semester);

      // Background refresh
      _refreshSelectedSemesterInBackground(year, semester, generation);
      return true;
    }

    // No cache — fetch from network. Old grades stay visible while loading.
    final result = await provider.fetchGrades(year, semester);

    if (!mounted || generation != _requestGeneration) return false;
    if (!result.success || result.data == null) return false;

    final entry = provider.getCachedGrades(year, semester);
    setState(() {
      _selectedYear = year;
      _selectedSemester = semester;
      _grades = result.data!;
      _lastUpdatedAt = entry?.updatedAt;
      _activeFilter = '全部';
      _pageState =
          _grades.isEmpty ? GradePageState.empty : GradePageState.content;
    });

    _saveSelectedSemester(year, semester);
    return true;
  }

  void _saveSelectedSemester(String year, int semester) {
    final userId = _lastUserId;
    if (userId == null) return;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('edu_last_semester_$userId', '${year}_$semester');
    });
  }

  Future<void> _refreshSelectedSemesterInBackground(
    String year,
    int semester,
    int generation,
  ) async {
    final provider = _eduProvider;
    if (provider == null) return;
    final result = await provider.fetchGrades(year, semester);
    if (!mounted || generation != _requestGeneration) return;
    if (result.success && result.data != null) {
      final entry = provider.getCachedGrades(year, semester);
      setState(() {
        _grades = result.data!;
        _lastUpdatedAt = entry?.updatedAt;
        _pageState =
            _grades.isEmpty ? GradePageState.empty : GradePageState.content;
      });
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }

  List<EduGrade> get _filteredGrades {
    switch (_activeFilter) {
      case '学位课':
        return _grades.where((g) => g.isDegree).toList();
      case '未通过':
        return _grades.where((g) => g.isPassed == false).toList();
      default:
        return _grades;
    }
  }

  List<EduAcademicCourse> get _filteredAcademicCourses {
    final courses = _academicSituation?.courses ?? const <EduAcademicCourse>[];
    switch (_academicFilter) {
      case '学位课':
        return courses.where((c) => c.isDegree).toList();
      case '未通过':
        return courses
            .where((c) =>
                c.effectivePassed == false || c.displayStatus.contains('未通过'))
            .toList();
      case '在读':
        return courses.where((c) => c.displayStatus.contains('在读')).toList();
      case '重修':
        return courses.where((c) => c.hasRetake).toList();
      default:
        return courses;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      endDrawerEnableOpenDragGesture: false,
      drawerScrimColor: Colors.black.withValues(alpha: 0.42),
      endDrawer: GradeManageDrawer(
        selectedYear: _selectedYear,
        selectedSemester: _selectedSemester,
        enrollmentYear: _eduProvider?.enrollmentYear ?? 2000,
        onSemesterChanged: _switchSemester,
        onRefresh: _refreshCurrentView,
      ),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('我的成绩'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: '成绩管理',
            icon: const Icon(Icons.menu_rounded),
            onPressed: () {
              _scaffoldKey.currentState?.openEndDrawer();
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: GradeGpaHeroCard(
            situation: _academicSituation,
            isLoading: _isAcademicLoading,
            errorMessage: _academicError,
            onRetry: () => _loadAcademicSituation(forceRefresh: true),
          ),
        ),
        SliverToBoxAdapter(child: _buildViewSwitcher()),
        if (_viewMode == GradeViewMode.academic)
          ..._buildAcademicContent()
        else
          ..._buildTermContent(),
      ],
    );
  }

  Widget _buildViewSwitcher() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: SegmentedButton<GradeViewMode>(
        segments: const [
          ButtonSegment(
            value: GradeViewMode.academic,
            label: Text('学业总览'),
          ),
          ButtonSegment(
            value: GradeViewMode.term,
            label: Text('学期成绩'),
          ),
        ],
        selected: {_viewMode},
        showSelectedIcon: false,
        onSelectionChanged: (value) {
          setState(() => _viewMode = value.first);
        },
      ),
    );
  }

  List<Widget> _buildAcademicContent() {
    if (_isAcademicLoading && _academicSituation == null) {
      return const [
        SliverToBoxAdapter(
          child: GradeEmptyState(state: GradePageState.loading),
        ),
      ];
    }

    if (_academicError != null && _academicSituation == null) {
      return [
        SliverToBoxAdapter(
          child: GradeEmptyState(
            state: GradePageState.error,
            errorMessage: _academicError,
            onRetry: () => _loadAcademicSituation(forceRefresh: true),
          ),
        ),
      ];
    }

    final courses = _academicSituation?.courses ?? const <EduAcademicCourse>[];
    if (courses.isEmpty) {
      return const [
        SliverToBoxAdapter(
          child: GradeEmptyState(
            state: GradePageState.empty,
            isFilterEmpty: false,
          ),
        ),
      ];
    }

    return [
      SliverToBoxAdapter(child: _buildAcademicSectionHeader()),
      if (_filteredAcademicCourses.isNotEmpty)
        SliverToBoxAdapter(child: _buildAcademicCourseList())
      else
        const SliverToBoxAdapter(
          child: GradeEmptyState(
            state: GradePageState.empty,
            isFilterEmpty: true,
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ];
  }

  List<Widget> _buildTermContent() {
    return [
      SliverToBoxAdapter(
        child: GradeSummaryCard(
          selectedYear: _selectedYear,
          selectedSemester: _selectedSemester,
          grades: _grades,
        ),
      ),
      if (_pageState == GradePageState.loading && _grades.isEmpty)
        const SliverToBoxAdapter(
          child: GradeEmptyState(state: GradePageState.loading),
        ),
      if (_pageState == GradePageState.error && _grades.isEmpty)
        SliverToBoxAdapter(
          child: GradeEmptyState(
            state: GradePageState.error,
            errorMessage: _errorMessage,
            onRetry: _loadGrades,
          ),
        ),
      if (_pageState == GradePageState.empty && _grades.isEmpty)
        const SliverToBoxAdapter(
          child: GradeEmptyState(
            state: GradePageState.empty,
            isFilterEmpty: false,
          ),
        ),
      if (_grades.isNotEmpty) ...[
        SliverToBoxAdapter(child: _buildCourseSectionHeader()),
        if (_filteredGrades.isNotEmpty)
          SliverToBoxAdapter(child: _buildTermCourseList())
        else
          const SliverToBoxAdapter(
            child: GradeEmptyState(
              state: GradePageState.empty,
              isFilterEmpty: true,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    ];
  }

  Widget _buildAcademicSectionHeader() {
    final courses = _academicSituation?.courses ?? const <EduAcademicCourse>[];
    final degreeCount = courses.where((c) => c.isDegree).length;
    final failedCount = courses
        .where((c) =>
            c.effectivePassed == false || c.displayStatus.contains('未通过'))
        .length;
    final inProgressCount =
        courses.where((c) => c.displayStatus.contains('在读')).length;
    final retakeCount = courses.where((c) => c.hasRetake).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '课程完成情况',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600],
                ),
              ),
              const Spacer(),
              if (_isAcademicRefreshing)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.grey[500],
                    ),
                  ),
                ),
              Text(
                '共 ${courses.length} 门',
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _academicFilterChip('全部 ${courses.length}', '全部'),
              _academicFilterChip('学位课 $degreeCount', '学位课'),
              _academicFilterChip('未通过 $failedCount', '未通过'),
              _academicFilterChip('在读 $inProgressCount', '在读'),
              _academicFilterChip('重修 $retakeCount', '重修'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAcademicCourseList() {
    return _courseListContainer(
      itemCount: _filteredAcademicCourses.length,
      itemBuilder: (context, index) {
        final course = _filteredAcademicCourses[index];
        return AcademicCourseItem(
          course: course,
          onTap: () => _openAcademicCourseDetail(course),
        );
      },
    );
  }

  Widget _buildTermCourseList() {
    return _courseListContainer(
      itemCount: _filteredGrades.length,
      itemBuilder: (context, index) {
        final grade = _filteredGrades[index];
        return GradeCourseItem(
          grade: grade,
          onTap: () => _openTermGradeDetail(grade),
        );
      },
    );
  }

  Widget _courseListContainer({
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.grey[850]
            : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
        ),
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: itemCount,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 16,
          endIndent: 16,
          color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
        ),
        itemBuilder: itemBuilder,
      ),
    );
  }

  void _openAcademicCourseDetail(EduAcademicCourse course) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => EduAcademicCourseDetailScreen(
          course: course,
        ),
        transitionsBuilder: _detailTransition,
      ),
    );
  }

  void _openTermGradeDetail(EduGrade grade) {
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => EduGradeDetailScreen(
          grade: grade,
          year: _selectedYear,
          semester: _selectedSemester,
        ),
        transitionsBuilder: _detailTransition,
      ),
    );
  }

  Widget _detailTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: AppMotion.incoming,
      reverseCurve: AppMotion.outgoing,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.08, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }

  Widget _buildCourseSectionHeader() {
    final degreeCount = _grades.where((g) => g.isDegree).length;
    final failedCount = _grades.where((g) => g.isPassed == false).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // "课程成绩  共 N 门" title
          Row(
            children: [
              Text(
                '课程成绩',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[600],
                ),
              ),
              const Spacer(),
              Text(
                '共 ${_grades.length} 门',
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Filter chips with counts
          Wrap(
            spacing: 8,
            children: [
              _filterChip('全部 ${_grades.length}', '全部'),
              _filterChip('学位课 $degreeCount', '学位课'),
              _filterChip('不及格记录 $failedCount', '未通过'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String filterKey) {
    final selected = _activeFilter == filterKey;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      selected: selected,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (_) {
        setState(() => _activeFilter = filterKey);
      },
    );
  }

  Widget _academicFilterChip(String label, String filterKey) {
    final selected = _academicFilter == filterKey;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      selected: selected,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: (_) {
        setState(() => _academicFilter = filterKey);
      },
    );
  }
}
