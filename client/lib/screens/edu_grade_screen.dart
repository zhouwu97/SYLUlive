import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/edu_provider.dart';
import '../providers/auth_provider.dart';
import '../models/edu_academic_situation.dart';
import '../models/edu_credit_requirement.dart';
import '../models/edu_grade.dart';
import '../theme/app_motion.dart';
import '../utils/edu_semester_utils.dart';
import '../utils/grade_screen_registry.dart';
import '../widgets/edu_grade/grade_summary_card.dart';
import '../widgets/edu_grade/grade_course_item.dart';
import '../widgets/edu_grade/grade_empty_state.dart';
import '../widgets/edu_grade/academic_privacy_notice.dart';
import '../widgets/edu_grade/grade_center_section_tabs.dart';
import '../widgets/edu_grade/academic_requirement_overview.dart';
import '../widgets/edu_grade/improvement_course_section.dart';
import 'edu_grade_detail_screen.dart';
import '../widgets/edu_grade/grade_manage_drawer.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

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
  GradeCenterSection _section = GradeCenterSection.term;

  // Credit requirement state
  EduCreditRequirementOverview? _creditRequirements;
  bool _isRequirementLoading = false;
  String? _requirementError;
  int _requirementRequestGeneration = 0;
  Future<void>? _creditRequirementsLoadFuture;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ScrollController _termScrollController = ScrollController();
  final ScrollController _overviewScrollController = ScrollController();

  EduProvider? _eduProvider;

  @override
  void initState() {
    super.initState();
    GradeScreenRegistry.register(this);
  }

  @override
  void dispose() {
    GradeScreenRegistry.unregister(this);
    _termScrollController.dispose();
    _overviewScrollController.dispose();
    super.dispose();
  }

  @override
  bool get canHandleGradeLink =>
      mounted && (ModalRoute.of(context)?.isCurrent ?? false);

  @override
  Future<bool> switchToGradeSemester(String year, int semester) async {
    _switchSection(GradeCenterSection.term, scrollToTop: true);
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
    final authProvider = context.watch<AuthProvider>();
    final currentUserId = authProvider.user?.id.toString();

    if (_eduProvider != eduProvider || _lastUserId != currentUserId) {
      _eduProvider = eduProvider;
      _lastUserId = currentUserId;

      // 立即废弃旧用户的所有进行中请求并清空页面
      _requestGeneration++;
      _academicRequestGeneration++;
      _requirementRequestGeneration++;
      _creditRequirementsLoadFuture = null;
      setState(() {
        _grades = [];
        _academicSituation = null;
        _creditRequirements = null;
        _lastUpdatedAt = null;
        _activeFilter = '全部';
        _errorMessage = null;
        _academicError = null;
        _requirementError = null;
        _section = GradeCenterSection.term;
        _pageState = GradePageState.loading;
        _isInitialLoading = true;
        _isRefreshing = false;
        _isAcademicLoading = true;
        _isRequirementLoading = false;
      });
      _resetSectionScrollPositions();

      if (currentUserId != null) {
        // 捕获局部变量防止异步期间 _lastUserId 变化
        final capturedUserId = currentUserId;
        eduProvider.setUserId(currentUserId);
        Future<void> initFlow() async {
          await eduProvider.ensureStatusLoaded();
          if (!mounted || _lastUserId != capturedUserId) return;
          if (!eduProvider.isBound) {
            _showUnavailableState('请先绑定教务账号');
            return;
          }
          await _initSemesterAndLoad(capturedUserId);
        }

        initFlow();
      } else {
        _showUnavailableState('请先登录后查看成绩');
      }
    }
  }

  void _showUnavailableState(String message) {
    if (!mounted) return;
    setState(() {
      _grades = const <EduGrade>[];
      _academicSituation = null;
      _creditRequirements = null;
      _pageState = GradePageState.error;
      _errorMessage = message;
      _academicError = message;
      _requirementError = message;
      _isInitialLoading = false;
      _isRefreshing = false;
      _isAcademicLoading = false;
      _isRequirementLoading = false;
    });
  }

  Future<void> _initSemesterAndLoad(String userId) async {
    // Load persisted semester
    final prefs = await AppPreferencesStore.getInstance();
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

    // 仅在当前数据源声明支持时预取 GPA；本机直连尚未迁移该能力，不能
    // 触发旧服务端接口，也不能拿旧来源缓存填充当前页面。
    if (_eduProvider?.academicCapabilities.supportsAcademicSituation ?? true) {
      unawaited(_loadAcademicSituation());
    } else {
      _markUnsupportedAcademicFeatures();
    }
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
    if (provider.isUsingLocalAcademicSession &&
        !provider.academicCapabilities.supportsAcademicSituation) {
      _markUnsupportedAcademicFeatures();
      return;
    }

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
    final result = await provider.fetchAcademicSituation();

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

  Future<void> _loadCreditRequirements({bool forceRefresh = false}) {
    final activeRequest = _creditRequirementsLoadFuture;
    if (activeRequest != null) return activeRequest;

    late final Future<void> request;
    request = _performLoadCreditRequirements(forceRefresh: forceRefresh);
    _creditRequirementsLoadFuture = request;
    return request.whenComplete(() {
      if (identical(_creditRequirementsLoadFuture, request)) {
        _creditRequirementsLoadFuture = null;
      }
    });
  }

  Future<void> _performLoadCreditRequirements({
    bool forceRefresh = false,
  }) async {
    final provider = _eduProvider;
    if (provider == null) return;
    if (provider.isUsingLocalAcademicSession &&
        !provider.academicCapabilities.supportsCreditRequirements) {
      _markUnsupportedAcademicFeatures();
      return;
    }

    final cache = provider.getCachedCreditRequirements();

    if (cache != null && !forceRefresh) {
      setState(() {
        _creditRequirements = cache.data;
        _isRequirementLoading = false;
        _requirementError = null;
      });
    } else {
      setState(() {
        _isRequirementLoading = _creditRequirements == null;
        _requirementError = null;
      });
    }

    final gen = ++_requirementRequestGeneration;
    final result = await provider.fetchCreditRequirements();

    if (!mounted || _requirementRequestGeneration != gen) return;

    if (result.success && result.data != null) {
      setState(() {
        _creditRequirements = result.data!;
        _isRequirementLoading = false;
        _requirementError = null;
      });
      return;
    }

    debugPrint(
      '[CREDIT-REQ] load failed: ${result.errorMessage ?? '学分要求获取失败'}',
    );
    setState(() {
      _isRequirementLoading = false;
      _requirementError = result.errorMessage ?? '学分要求获取失败';
    });
  }

  Future<bool> _refreshCreditRequirements({
    bool showMessage = true,
  }) async {
    if (_isRequirementLoading) return false;
    await _loadCreditRequirements(forceRefresh: true);
    final success = _requirementError == null && _creditRequirements != null;
    if (mounted && showMessage) {
      _showSnackBar(success ? '学分要求已更新' : '学分要求获取失败');
    }
    return success;
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
      _prefetchGradeDetails(cache.grades);
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
      _prefetchGradeDetails(result.data!);
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
      _prefetchGradeDetails(result.data!);
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

  Future<bool> _refreshAcademicSituation({bool showMessage = true}) async {
    if (_isAcademicLoading) return false;
    await _loadAcademicSituation(forceRefresh: true);
    final success = _academicError == null && _academicSituation != null;
    if (mounted && showMessage) {
      _showSnackBar(success ? '学业情况已更新' : '刷新失败，请稍后重试');
    }
    return success;
  }

  /// 刷新学业总览：同时刷新 GPA 和学分要求。
  Future<bool> _refreshAcademicOverview() async {
    final gpaSuccess = await _refreshAcademicSituation(showMessage: false);

    final requirementSuccess =
        await _refreshCreditRequirements(showMessage: false);

    if (!mounted) return false;

    if (gpaSuccess && requirementSuccess) {
      _showSnackBar('学业总览已更新');
      return true;
    }

    if (gpaSuccess) {
      _showSnackBar('GPA已更新，学分要求获取失败');
      return false;
    }

    if (requirementSuccess) {
      _showSnackBar('学分要求已更新，GPA获取失败');
      return false;
    }

    _showSnackBar('学业总览刷新失败');
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
      _prefetchGradeDetails(cache.grades, year: year, semester: semester);

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
    _prefetchGradeDetails(result.data!, year: year, semester: semester);
    return true;
  }

  void _saveSelectedSemester(String year, int semester) {
    final userId = _lastUserId;
    if (userId == null) return;
    _saveSelectedSemesterFor(userId, year, semester);
  }

  void _saveSelectedSemesterFor(String userId, String year, int semester) {
    AppPreferencesStore.getInstance().then((prefs) {
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
      _prefetchGradeDetails(result.data!, year: year, semester: semester);
    }
  }

  void _prefetchGradeDetails(
    List<EduGrade> grades, {
    String? year,
    int? semester,
  }) {
    final provider = _eduProvider;
    if (provider == null || grades.isEmpty) return;
    unawaited(
      provider.prefetchGradeDetails(
        grades,
        year ?? _selectedYear,
        semester ?? _selectedSemester,
      ),
    );
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
        academicUnavailableMessage: _eduProvider?.isUsingLocalAcademicSession ==
                    true &&
                !_eduProvider!.academicCapabilities.supportsAcademicSituation
            ? '本机直连暂不支持官方 GPA'
            : null,
        isAcademicRefreshing: _isAcademicLoading || _isRequirementLoading,
        onRefreshAcademic: _refreshAcademicOverview,
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
    return Column(
      children: [
        GradeCenterSectionTabs(
          selected: _section,
          onChanged: _switchSection,
        ),
        Expanded(
          child: IndexedStack(
            index: _section.index,
            children: [
              CustomScrollView(
                key: const ValueKey('grade_term_scroll_view'),
                controller: _termScrollController,
                slivers: _buildTermContent(),
              ),
              CustomScrollView(
                key: const ValueKey('grade_overview_scroll_view'),
                controller: _overviewScrollController,
                slivers: _buildAcademicContent(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _switchSection(
    GradeCenterSection section, {
    bool scrollToTop = false,
  }) {
    if (_section != section) {
      setState(() => _section = section);
    }
    if (scrollToTop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpToTop(_controllerFor(section));
      });
    }

    // If switching to overview and no cached data, trigger loads
    if (section == GradeCenterSection.overview) {
      _ensureAcademicContentLoaded();
    }
  }

  void _ensureAcademicContentLoaded() {
    final provider = _eduProvider;
    if (provider?.isUsingLocalAcademicSession == true &&
        (!provider!.academicCapabilities.supportsAcademicSituation ||
            !provider.academicCapabilities.supportsCreditRequirements)) {
      _markUnsupportedAcademicFeatures();
      return;
    }
    if (_academicSituation == null &&
        _academicError == null &&
        !_isAcademicLoading) {
      unawaited(_loadAcademicSituation());
    }
    if (_creditRequirements == null &&
        _requirementError == null &&
        !_isRequirementLoading) {
      unawaited(_loadCreditRequirements());
    }
  }

  void _markUnsupportedAcademicFeatures() {
    final provider = _eduProvider;
    if (!mounted || provider == null || !provider.isUsingLocalAcademicSession) {
      return;
    }
    final capabilities = provider.academicCapabilities;
    setState(() {
      if (!capabilities.supportsAcademicSituation) {
        _academicSituation = null;
        _isAcademicLoading = false;
        _academicError = '本机直连暂不支持官方 GPA';
      }
      if (!capabilities.supportsCreditRequirements) {
        _creditRequirements = null;
        _isRequirementLoading = false;
        _requirementError = '本机直连暂不支持学分要求';
      }
    });
  }

  ScrollController _controllerFor(GradeCenterSection section) {
    return switch (section) {
      GradeCenterSection.term => _termScrollController,
      GradeCenterSection.overview => _overviewScrollController,
    };
  }

  void _resetSectionScrollPositions() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToTop(_termScrollController);
      _jumpToTop(_overviewScrollController);
    });
  }

  void _jumpToTop(ScrollController controller) {
    if (controller.hasClients) controller.jumpTo(0);
  }

  List<Widget> _buildAcademicContent() {
    return [
      // 学分要求模块
      SliverToBoxAdapter(
        child: AcademicRequirementOverview(
          requirements: _creditRequirements,
          isLoading: _isRequirementLoading,
          isBackgroundRefresh:
              _isRequirementLoading && _creditRequirements != null,
          errorMessage: _requirementError,
          hasCache: _creditRequirements != null,
          onRetry: () => _loadCreditRequirements(forceRefresh: true),
        ),
      ),

      // 提高课程
      if (_creditRequirements != null &&
          _creditRequirements!.improvementCourses.isNotEmpty)
        SliverToBoxAdapter(
          child: ImprovementCourseSection(
            courses: _creditRequirements!.improvementCourses,
          ),
        ),

      const SliverToBoxAdapter(child: AcademicPrivacyNotice()),
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
