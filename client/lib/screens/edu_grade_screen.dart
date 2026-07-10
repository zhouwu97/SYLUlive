import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/edu_provider.dart';
import '../providers/auth_provider.dart';
import '../models/edu_academic_situation.dart';
import '../models/edu_grade.dart';
import '../utils/app_motion.dart';
import '../utils/edu_semester_utils.dart';
import '../utils/grade_screen_registry.dart';
import '../services/grade_reminder_service.dart';
import '../widgets/edu_grade/grade_summary_card.dart';
import '../widgets/edu_grade/grade_course_item.dart';
import '../widgets/edu_grade/grade_empty_state.dart';
import 'edu_grade_detail_screen.dart';
import '../widgets/edu_grade/grade_manage_drawer.dart';

// GradeViewMode removed

class EduGradeScreen extends StatefulWidget {
  final String? initialYear;
  final int? initialSemester;

  const EduGradeScreen({
    super.key,
    this.initialYear,
    this.initialSemester,
  });

  @override
  State<EduGradeScreen> createState() => _EduGradeScreenState();
}

class _EduGradeScreenState extends State<EduGradeScreen>
    implements GradeScreenLinkTarget {
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
  EduAcademicSituation? _academicSituation;
  bool _isAcademicLoading = false;
  String? _academicError;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  EduProvider? _eduProvider;

  @override
  void initState() {
    super.initState();
    GradeScreenRegistry.register(this);
  }

  @override
  void dispose() {
    GradeScreenRegistry.unregister(this);
    super.dispose();
  }

  @override
  bool get canHandleGradeLink =>
      mounted && (ModalRoute.of(context)?.isCurrent ?? false);

  @override
  Future<bool> switchToGradeSemester(String year, int semester) async {
    if (year == _selectedYear && semester == _selectedSemester) {
      final grades = await _refreshGrades();
      return grades != null;
    }
    return _switchSemester(year, semester);
  }

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
        _errorMessage = null;
        _academicError = null;
        _pageState = GradePageState.loading;
        _isInitialLoading = true;
        _isRefreshing = false;
        _isAcademicLoading = true;
      });

      if (currentUserId != null) {
        // 捕获局部变量防止异步期间 _lastUserId 变化
        final capturedUserId = currentUserId;
        eduProvider.setUserId(currentUserId);
        unawaited(
          GradeReminderService.instance.syncRuntimeConfig(
            userId: currentUserId,
          ),
        );
        unawaited(
          GradeReminderService.instance.ensureScheduledIfEnabled(),
        );
        _initSemesterAndLoad(capturedUserId);
      } else {
        unawaited(
            GradeReminderService.instance.syncRuntimeConfig(userId: null));
      }
    }
  }

  Future<void> _initSemesterAndLoad(String userId) async {
    // Load persisted semester
    final prefs = await SharedPreferences.getInstance();
    final savedKey = 'edu_last_semester_$userId';
    final saved = prefs.getString(savedKey);

    bool loaded = _tryUseInitialSemester(userId);
    if (!loaded && saved != null) {
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
    await _loadGrades();
    if (!mounted) return;
    await _loadAcademicSituation();
  }

  bool _tryUseInitialSemester(String userId) {
    final year = widget.initialYear;
    final semester = widget.initialSemester;
    if (year == null || semester == null) return false;
    final enrollmentYear = _eduProvider?.enrollmentYear ?? 2000;
    final cur = EduSemester.current();
    final curYear = int.tryParse(cur.year) ?? DateTime.now().year;
    final yearNumber = int.tryParse(year);
    if (yearNumber == null ||
        !EduSemester.isValid(semester) ||
        yearNumber < enrollmentYear ||
        (yearNumber > curYear ||
            (yearNumber == curYear && semester > cur.semester))) {
      return false;
    }
    _selectedYear = year;
    _selectedSemester = semester;
    _saveSelectedSemesterFor(userId, year, semester);
    return true;
  }

  Future<void> _loadAcademicSituation({bool forceRefresh = false}) async {
    final provider = _eduProvider;
    if (provider == null) return;

    final cache = provider.getCachedAcademicSituation();
    if (cache != null && !forceRefresh) {
      setState(() {
        _academicSituation = cache.data;
        _isAcademicLoading = false;
        _academicError = null;
      });
    } else {
      setState(() {
        _isAcademicLoading = _academicSituation == null;
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
        _academicError = null;
      });
      return;
    }

    setState(() {
      _isAcademicLoading = false;
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
      _syncBaselineAndCancelNotification(
          _selectedYear, _selectedSemester, result.data!);
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

  Future<List<EduGrade>?> _refreshGrades({bool silent = false}) async {
    if (_isInitialLoading || _isRefreshing) return null;
    if (_eduProvider == null) return null;

    setState(() => _isRefreshing = true);

    final gen = ++_requestGeneration;
    final result =
        await _eduProvider!.fetchGrades(_selectedYear, _selectedSemester);

    if (!mounted || _requestGeneration != gen) {
      // 页面已切换或用户变化 → 视为失败
      return null;
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
      _syncBaselineAndCancelNotification(
          _selectedYear, _selectedSemester, result.data!);
      if (mounted && !silent) _showSnackBar('成绩已更新');
      return result.data;
    }

    setState(() => _isRefreshing = false);
    if (mounted && !silent) _showSnackBar('刷新失败，请稍后重试');
    return null;
  }

  Future<List<EduGrade>?> _refreshCurrentView({bool silent = false}) {
    return _refreshGrades(silent: silent);
  }

  Future<bool> _refreshAcademicSituation() async {
    if (_isAcademicLoading) return false;
    await _loadAcademicSituation(forceRefresh: true);
    final success = _academicError == null && _academicSituation != null;
    if (mounted) _showSnackBar(success ? '学业情况已更新' : '刷新失败，请稍后重试');
    return success;
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

    _syncBaselineAndCancelNotification(year, semester, result.data!);
    _saveSelectedSemester(year, semester);
    return true;
  }

  void _saveSelectedSemester(String year, int semester) {
    final userId = _lastUserId;
    if (userId == null) return;
    _saveSelectedSemesterFor(userId, year, semester);
  }

  void _syncBaselineAndCancelNotification(
      String year, int semester, List<EduGrade> grades) {
    final userId = _lastUserId;
    if (userId == null) return;
    unawaited(
      GradeReminderService.instance.syncBaselineIfEnabled(
        userId: userId,
        year: year,
        semester: semester,
        grades: grades,
      ),
    );
    unawaited(
      GradeReminderService.instance.clearGradeUpdateNotifications(),
    );
  }

  void _saveSelectedSemesterFor(String userId, String year, int semester) {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('edu_last_semester_$userId', '${year}_$semester');
    });
    unawaited(
      GradeReminderService.instance.syncSelectedSemester(
        userId: userId,
        year: year,
        semester: semester,
      ),
    );
    unawaited(
      GradeReminderService.instance.ensureScheduledIfEnabled(),
    );
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
      _syncBaselineAndCancelNotification(year, semester, result.data!);
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
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF111315)
          : const Color(0xFFFFFAF4),
      endDrawerEnableOpenDragGesture: false,
      drawerScrimColor: Colors.black.withValues(alpha: 0.42),
      endDrawer: GradeManageDrawer(
        selectedYear: _selectedYear,
        selectedSemester: _selectedSemester,
        grades: _grades,
        userId: _lastUserId,
        isEduBound: _eduProvider?.isBound ?? false,
        enrollmentYear: _eduProvider?.enrollmentYear ?? 2000,
        onSemesterChanged: _switchSemester,
        onRefreshGrades: _refreshCurrentView,
        academicSituation: _academicSituation,
        isAcademicRefreshing: _isAcademicLoading,
        onRefreshAcademic: _refreshAcademicSituation,
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
        ..._buildTermContent(),
      ],
    );
  }

  // Academic content builders removed

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
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final grade = _filteredGrades[index];
                  return GradeCourseItem(
                    grade: grade,
                    onTap: () => _openTermGradeDetail(grade),
                  );
                },
                childCount: _filteredGrades.length,
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
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    ];
  }

  // Academic course detail navigation removed

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

  String _activeFilterLabel() {
    final degreeCount = _grades.where((g) => g.isDegree).length;
    final failedCount = _grades.where((g) => g.isPassed == false).length;

    switch (_activeFilter) {
      case '学位课':
        return '学位课 $degreeCount';
      case '未通过':
        return '未通过 $failedCount';
      default:
        return '全部 ${_grades.length}';
    }
  }

  void _showGradeFilterSheet() {
    final degreeCount = _grades.where((g) => g.isDegree).length;
    final failedCount = _grades.where((g) => g.isPassed == false).length;

    final options = <Map<String, String>>[
      {'key': '全部', 'label': '全部 ${_grades.length}'},
      {'key': '学位课', 'label': '学位课 $degreeCount'},
      {'key': '未通过', 'label': '未通过 $failedCount'},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1D2024) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.grey.shade700
                          : const Color(0xFFE1E4E8),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const Text(
                  '筛选课程',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                for (final option in options)
                  _filterSheetItem(
                    label: option['label']!,
                    selected: _activeFilter == option['key'],
                    onTap: () {
                      setState(() => _activeFilter = option['key']!);
                      Navigator.pop(context);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _filterSheetItem({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);

    return Material(
      color: selected
          ? accent.withValues(alpha: isDark ? 0.16 : 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? accent
                        : isDark
                            ? Colors.grey.shade200
                            : const Color(0xFF2B2F33),
                  ),
                ),
              ),
              if (selected) Icon(Icons.check_rounded, size: 20, color: accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCourseSectionHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Row(
        children: [
          Text(
            '课程成绩',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF1F2328),
            ),
          ),
          const Spacer(),
          Material(
            color: accent.withValues(alpha: isDark ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: _showGradeFilterSheet,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _activeFilterLabel(),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: accent,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
