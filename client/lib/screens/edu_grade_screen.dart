import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/edu_provider.dart';
import '../providers/auth_provider.dart';
import '../models/edu_grade.dart';
import '../utils/edu_semester_utils.dart';
import '../widgets/edu_grade/grade_summary_card.dart';
import '../widgets/edu_grade/grade_course_item.dart';
import '../widgets/edu_grade/grade_empty_state.dart';
import 'edu_grade_detail_screen.dart';
import '../widgets/edu_grade/grade_manage_drawer.dart';

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
  String? _errorMessage;
  String? _lastUserId;
  String _activeFilter = '全部'; // '全部' | '学位课' | '未通过'

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
      setState(() {
        _grades = [];
        _lastUpdatedAt = null;
        _activeFilter = '全部';
        _errorMessage = null;
        _pageState = GradePageState.loading;
        _isInitialLoading = true;
        _isRefreshing = false;
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
    _loadGrades();
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
        onRefresh: _refreshGrades,
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
        // Unified overview card — always visible (shows semester + stats)
        SliverToBoxAdapter(
          child: GradeSummaryCard(
            selectedYear: _selectedYear,
            selectedSemester: _selectedSemester,
            grades: _grades,
          ),
        ),

        // Loading without cache
        if (_pageState == GradePageState.loading && _grades.isEmpty)
          const SliverToBoxAdapter(
            child: GradeEmptyState(state: GradePageState.loading),
          ),

        // Error without cache
        if (_pageState == GradePageState.error && _grades.isEmpty)
          SliverToBoxAdapter(
            child: GradeEmptyState(
              state: GradePageState.error,
              errorMessage: _errorMessage,
              onRetry: _loadGrades,
            ),
          ),

        // Empty (no grades at all)
        if (_pageState == GradePageState.empty && _grades.isEmpty)
          const SliverToBoxAdapter(
            child: GradeEmptyState(
              state: GradePageState.empty,
              isFilterEmpty: false,
            ),
          ),

        // Has grades — show course section
        if (_grades.isNotEmpty) ...[
          // "课程成绩  共 N 门" section header + filter chips
          SliverToBoxAdapter(
            child: _buildCourseSectionHeader(),
          ),

          // Course list or filter-empty state
          if (_filteredGrades.isNotEmpty)
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey[850]
                      : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color:
                        Theme.of(context).dividerColor.withValues(alpha: 0.3),
                  ),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _filteredGrades.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color:
                        Theme.of(context).dividerColor.withValues(alpha: 0.3),
                  ),
                  itemBuilder: (context, index) {
                    return GradeCourseItem(
                      grade: _filteredGrades[index],
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => EduGradeDetailScreen(
                              grade: _filteredGrades[index],
                              year: _selectedYear,
                              semester: _selectedSemester,
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            )
          else
            const SliverToBoxAdapter(
              child: GradeEmptyState(
                state: GradePageState.empty,
                isFilterEmpty: true,
              ),
            ),

          // Bottom padding
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ],
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
}
