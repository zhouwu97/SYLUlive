import 'dart:async';
import '../features/academic/application/academic_session_controller.dart';
import '../features/academic/application/academic_login_coordinator.dart';
import '../features/academic/presentation/academic_login_dialog.dart';

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
import '../widgets/edu_grade/grade_session_notice.dart';
import '../widgets/edu_grade/academic_privacy_notice.dart';
import '../widgets/edu_grade/grade_center_section_tabs.dart';
import '../widgets/edu_grade/academic_requirement_overview.dart';
import '../widgets/edu_grade/improvement_course_section.dart';
import '../widgets/edu_grade/academic_situation_card.dart';
import 'edu_grade_detail_screen.dart';
import '../widgets/edu_grade/grade_manage_drawer.dart';
import 'grade_refresh_policy.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';

class EduGradeScreen extends StatefulWidget {
  final String? initialYear;
  final int? initialSemester;

  /// 仅用于测试：把前台恢复的时间窗注入进来，让 resume 分支能在 widget 测试里
  /// 真实触发，而不是绕开时间条件去断言别的代码路径。
  @visibleForTesting
  final Duration? resumeRefreshCooldown;

  const EduGradeScreen({
    super.key,
    this.initialYear,
    this.initialSemester,
    this.resumeRefreshCooldown,
  });

  @override
  State<EduGradeScreen> createState() => _EduGradeScreenState();
}

class _EduGradeScreenState extends State<EduGradeScreen>
    with WidgetsBindingObserver
    implements GradeScreenLinkTarget {
  static const Duration _autoRefreshCooldown = Duration(minutes: 15);
  static const Duration _failureRetryCooldown = Duration(minutes: 2);

  /// 生产默认 30 分钟；测试通过 [EduGradeScreen.resumeRefreshCooldown] 注入。
  Duration get _resumeRefreshCooldown =>
      widget.resumeRefreshCooldown ?? const Duration(minutes: 30);
  DateTime? _lastSuccessfulSyncTime;
  DateTime? _lastFetchFailureTime;
  DateTime? _academicUpdatedAt;
  final Set<String> _newlyAddedGradeKeys = <String>{};

  String _scopedGradeKey(String year, int semester, EduGrade grade) {
    return '$year|$semester|${GradeStableKey.of(grade)}';
  }

  /// 已经向用户提示过「本次返回成绩减少」的确认状态（计划 8.5）。
  ///
  /// 减少保护要求：首次遇到减少只提示、不写入；用户在明确提示之后**再次**发起刷新
  /// 才算确认覆盖。确认只对同一账号 / 教务身份 / 学期有效，期间切号或切学期一律失效，
  /// 且确认绑定提示时那份**具体候选结果**：重新请求后数量或课程集合再次变化时
  /// 必须重新判断、重新提示，不能复用旧确认（例如 20 -> 19 的确认不得授权 19 -> 0）。
  final GradeReductionConfirmation _reductionConfirmation =
      GradeReductionConfirmation();

  /// 当前成绩上下文的稳定标识：账号 / 教务身份 / 学期。
  String _gradeContextScope() {
    return '${_lastUserId ?? ''}|${_academicIdentityKey ?? ''}'
        '|$_selectedYear|$_selectedSemester';
  }

  /// 消费一次「减少确认」：仅当上一次提示与当前上下文完全一致时才成立。
  /// 返回上次提示所对应的候选结果指纹（无待确认提示时返回 null）。
  String? _consumeReductionConfirmation() {
    return _reductionConfirmation.consume(_gradeContextScope());
  }

  /// 「减少确认」要绑定的具体候选结果指纹：课程集合与门数的稳定标识。
  ///
  /// 只看门数不够——「20 门减到 19 门」的确认不能被复用来授权「19 门减到 0 门」：
  /// 重新请求后结果再次变化时，用户并没有对新的结果点过头。
  String _gradeReductionSignature(List<EduGrade> grades) {
    final keys = grades.map(GradeStableKey.of).toList()..sort();
    return '${keys.length}#${keys.join(',')}';
  }

  /// 保留旧结果并提示「本次返回成绩减少」，同时记录该提示所属的上下文与候选结果，
  /// 以便用户**再次**发起刷新时把这次提示消费成确认（计划 8.5）。
  void _rememberReductionWarning(int removedCount, String signature) {
    _reductionConfirmation.warn(_gradeContextScope(), signature);
    if (mounted) {
      _showSnackBar('本次返回成绩减少 $removedCount 门，已保留上次结果，请再次下拉刷新确认');
    }
  }

  String _selectedYear = '';
  int _selectedSemester = EduSemester.first;
  List<EduGrade> _grades = [];
  GradePageState _pageState = GradePageState.loading;
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
  AcademicSessionController? _academicSession;
  String? _academicContext;
  String? _academicIdentityKey;
  bool _wasSessionReady = false;
  bool _sessionReadBlocked = false;
  Future<bool>? _sessionReadFuture;

  String get _sessionMessage =>
      _academicSession?.failure?.message ?? '请先完成教务登录后重试';

  /// 会话需要人工登录、而页面上仍有可信结果可看时的非阻塞提示。
  /// 由会话状态推导，避免各处成功/失败分支漏掉清理。
  bool get _showsSessionNotice {
    final session = _academicSession;
    return session != null &&
        !session.isAuthenticated &&
        _pageState != GradePageState.error &&
        _grades.isNotEmpty;
  }

  Future<bool> _ensureReadReady({required bool allowInteractiveLogin}) async {
    final session = _academicSession;
    if (session == null) return true;
    final running = _sessionReadFuture;
    if (running != null) {
      await running;
      return mounted && (_academicSession?.isAuthenticated ?? false);
    }
    if (session.isAuthenticated) {
      _sessionReadBlocked = false;
      return true;
    }
    // 同一轮成绩、GPA 和学分读取共用一次恢复；取消后只由允许打断用户的来源再弹框。
    if (_sessionReadBlocked && !allowInteractiveLogin) return false;
    final identity = session.identity;
    final appUserId = session.appUserId;
    final operation = ensureAcademicSessionForRead(context,
        controller: session,
        coordinator: context.read<AcademicLoginCoordinator?>(),
        allowInteractiveLogin: allowInteractiveLogin);
    _sessionReadFuture = operation;
    try {
      final result = await operation;
      final sameIdentity = mounted &&
          session.identity == identity &&
          session.appUserId == appUserId;
      final ready = sameIdentity && (result || session.isAuthenticated);
      if (sameIdentity) _sessionReadBlocked = !ready;
      return ready;
    } finally {
      if (identical(_sessionReadFuture, operation)) _sessionReadFuture = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GradeScreenRegistry.register(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GradeScreenRegistry.unregister(this);
    _termScrollController.dispose();
    _overviewScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!mounted) return;
      final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? false;
      if (!isCurrentRoute) return;

      final now = DateTime.now();
      // 若最近一次请求失败，采用 2 分钟退避重试，避免断网恢复后被 30 分钟长冷却锁死
      if (_lastFetchFailureTime != null &&
          now.difference(_lastFetchFailureTime!) < _failureRetryCooldown) {
        return;
      }

      final lastSuccess = _lastSuccessfulSyncTime ?? _lastUpdatedAt;
      final shouldRefresh = lastSuccess == null ||
          now.difference(lastSuccess) > _resumeRefreshCooldown;

      if (shouldRefresh && !_isRefreshing && !_isInitialLoading) {
        unawaited(_refreshGrades(origin: GradeRefreshOrigin.resume));
      }
    }
  }

  @override
  bool get canHandleGradeLink =>
      mounted && (ModalRoute.of(context)?.isCurrent ?? false);

  @override
  Future<bool> switchToGradeSemester(String year, int semester) async {
    _switchSection(GradeCenterSection.term, scrollToTop: true);
    if (year == _selectedYear && semester == _selectedSemester) {
      final grades = await _refreshGrades(origin: GradeRefreshOrigin.manual);
      return grades != null;
    }
    return _switchSemester(year, semester);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final eduProvider = context.read<EduProvider>();
    final authProvider = context.watch<AuthProvider>();
    final session = context.watch<AcademicSessionController?>();
    final identityKey = session == null
        ? null
        : '${session.appUserId}|${session.identity?.storageId ?? session.studentId}';
    final sessionContext = session == null
        ? null
        : '${session.appUserId}|${session.identity?.storageId}|${session.contextGeneration}';
    final ready = session?.isAuthenticated ?? false;
    final becameReady = !_wasSessionReady && ready;
    _wasSessionReady = ready;
    _academicSession = session;
    final currentUserId = authProvider.user?.id.toString();

    if (_eduProvider != eduProvider ||
        _lastUserId != currentUserId ||
        _academicContext != sessionContext) {
      _academicContext = sessionContext;
      if (_academicIdentityKey != identityKey) _sessionReadBlocked = false;
      _academicIdentityKey = identityKey;
      _eduProvider = eduProvider;
      _lastUserId = currentUserId;

      // 立即废弃旧用户的所有进行中请求并清空页面
      _requestGeneration++;
      _academicRequestGeneration++;
      _requirementRequestGeneration++;
      _creditRequirementsLoadFuture = null;
      // 切号 / 切教务身份 / 切上下文：旧的「减少确认」不能作用到新账号的新结果上。
      _reductionConfirmation.reset();
      setState(() {
        _grades = [];
        _academicSituation = null;
        _creditRequirements = null;
        _lastUpdatedAt = null;
        _academicUpdatedAt = null;
        _newlyAddedGradeKeys.clear();
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
        final capturedContext = sessionContext;
        eduProvider.setUserId(currentUserId);
        Future<void> initFlow() async {
          await eduProvider.ensureStatusLoaded();
          if (!mounted ||
              _lastUserId != capturedUserId ||
              _academicContext != capturedContext) {
            return;
          }
          if (!eduProvider.isBound) {
            _showUnavailableState(eduProvider.errorMessage ?? '请先绑定教务账号');
            return;
          }
          if (!eduProvider.academicCapabilities.supportsGrades) {
            _showUnavailableState('当前教务暂未开放成绩与学业总览；研究生本版支持登录和课表');
            return;
          }
          await _initSemesterAndLoad(capturedUserId);
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              _lastUserId == capturedUserId &&
              _academicContext == capturedContext) {
            unawaited(initFlow());
          }
        });
      } else {
        _showUnavailableState('请先登录后查看成绩');
      }
    } else if (becameReady &&
        _sessionReadBlocked &&
        _sessionReadFuture == null) {
      _sessionReadBlocked = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _academicContext != sessionContext) return;
        // 登录/恢复成功是明确的会话边界，不能被新鲜缓存的 cache-only 决策吞掉；
        // 先展示缓存，再主动拉取一次，保证重新认证后页面拿到最新成绩。
        unawaited(_loadGrades(
            origin: GradeRefreshOrigin.sessionRecovered, forceRefresh: true));
        unawaited(
            _loadAcademicSituation(origin: GradeRefreshOrigin.sessionRecovered));
        if (_section == GradeCenterSection.overview) {
          unawaited(_loadCreditRequirements(
              origin: GradeRefreshOrigin.sessionRecovered));
        }
      });
    }
  }

  void _showUnavailableState(String message) {
    if (!mounted) return;
    setState(() {
      _grades = const <EduGrade>[];
      _academicSituation = null;
      _creditRequirements = null;
      _academicUpdatedAt = null;
      _newlyAddedGradeKeys.clear();
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
    final academicContext = _academicContext;
    // Load persisted semester
    final prefs = await AppPreferencesStore.getInstance();
    if (!mounted ||
        _lastUserId != userId ||
        _academicContext != academicContext) {
      return;
    }
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

        // 只解析一次，并保留 tryParse 的判空语义：学年串可能是
        // '2023-2024' 之类的脏数据，int.parse 会在 build 期间抛异常。
        final parsedYear = int.tryParse(year);
        if (sem != null &&
            EduSemester.isValid(sem) &&
            parsedYear != null &&
            parsedYear >= enrollmentYear &&
            (parsedYear < curYear ||
                (parsedYear == curYear && sem <= cur.semester))) {
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
    await _loadGrades(origin: GradeRefreshOrigin.initial);
    if (!mounted ||
        _lastUserId != userId ||
        _academicContext != academicContext) {
      return;
    }

    // 仅在当前数据源声明支持时预取 GPA；本机直连尚未迁移该能力，不能
    // 触发旧服务端接口，也不能拿旧来源缓存填充当前页面。
    // 来源是 automatic：首屏已经拿到过一次交互机会，联动读取不得再弹框。
    if (_eduProvider?.academicCapabilities.supportsAcademicSituation ?? true) {
      unawaited(_loadAcademicSituation(origin: GradeRefreshOrigin.automatic));
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

  Future<void> _loadAcademicSituation({
    required GradeRefreshOrigin origin,
    bool forceRefresh = false,
  }) async {
    final provider = _eduProvider;
    if (provider == null) return;
    if (provider.isUsingLocalAcademicSession &&
        !provider.academicCapabilities.supportsAcademicSituation) {
      _markUnsupportedAcademicFeatures();
      return;
    }

    final gen = ++_academicRequestGeneration;
    final cache = await provider.restoreCachedAcademicSituation();
    if (!mounted || _academicRequestGeneration != gen) return;
    if (cache != null && !forceRefresh) {
      setState(() {
        _academicSituation = cache.data;
        _academicUpdatedAt = cache.updatedAt;
        _isAcademicLoading = false;
        _academicError = null;
      });
    } else {
      setState(() {
        _isAcademicLoading = _academicSituation == null;
        _academicError = null;
      });
    }

    if (!await _ensureReadReady(
        allowInteractiveLogin: allowsInteractiveAcademicLogin(origin))) {
      if (mounted && _academicRequestGeneration == gen) {
        setState(() {
          _isAcademicLoading = false;
          _academicError = _sessionMessage;
        });
      }
      return;
    }
    if (!mounted || _academicRequestGeneration != gen) return;
    final result = await provider.fetchAcademicSituation(forceRefresh: true);

    if (!mounted || _academicRequestGeneration != gen) return;

    if (result.success && result.data != null) {
      setState(() {
        _academicSituation = result.data!;
        _academicUpdatedAt = DateTime.now();
        _isAcademicLoading = false;
        _academicError = null;
      });
      return;
    }

    setState(() {
      _isAcademicLoading = false;
      _academicError = result.errorMessage ?? '官方 GPA 获取失败';
      if (_academicSession?.isAuthenticated == false) {
        _sessionReadBlocked = true;
      }
    });
  }

  Future<void> _loadCreditRequirements({
    required GradeRefreshOrigin origin,
    bool forceRefresh = false,
  }) {
    final activeRequest = _creditRequirementsLoadFuture;
    if (activeRequest != null) return activeRequest;

    late final Future<void> request;
    request = _performLoadCreditRequirements(
        origin: origin, forceRefresh: forceRefresh);
    _creditRequirementsLoadFuture = request;
    return request.whenComplete(() {
      if (identical(_creditRequirementsLoadFuture, request)) {
        _creditRequirementsLoadFuture = null;
      }
    });
  }

  Future<void> _performLoadCreditRequirements({
    required GradeRefreshOrigin origin,
    bool forceRefresh = false,
  }) async {
    final provider = _eduProvider;
    if (provider == null) return;
    if (provider.isUsingLocalAcademicSession &&
        !provider.academicCapabilities.supportsCreditRequirements) {
      _markUnsupportedAcademicFeatures();
      return;
    }

    final gen = ++_requirementRequestGeneration;
    final cache = await provider.restoreCachedCreditRequirements();
    if (!mounted || _requirementRequestGeneration != gen) return;

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

    if (!await _ensureReadReady(
        allowInteractiveLogin: allowsInteractiveAcademicLogin(origin))) {
      if (mounted && _requirementRequestGeneration == gen) {
        setState(() {
          _isRequirementLoading = false;
          _requirementError = _sessionMessage;
        });
      }
      return;
    }
    if (!mounted || _requirementRequestGeneration != gen) return;
    final result = await provider.fetchCreditRequirements(forceRefresh: true);

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
      if (_academicSession?.isAuthenticated == false) {
        _sessionReadBlocked = true;
      }
    });
  }

  Future<bool> _refreshCreditRequirements({
    bool showMessage = true,
  }) async {
    if (_isRequirementLoading) return false;
    await _loadCreditRequirements(
        origin: GradeRefreshOrigin.manual, forceRefresh: true);
    final success = _requirementError == null && _creditRequirements != null;
    if (mounted && showMessage) {
      _showSnackBar(success ? '学分要求已更新' : '学分要求获取失败');
    }
    return success;
  }

  Future<void> _loadGrades({
    required GradeRefreshOrigin origin,
    bool forceRefresh = false,
  }) async {
    if (_eduProvider == null) return;

    final gen = ++_requestGeneration;
    final cache = await _eduProvider!
        .restoreCachedGrades(_selectedYear, _selectedSemester);
    if (!mounted || _requestGeneration != gen) return;

    final hasCredibleBaseline = cache != null;

    if (cache != null) {
      final now = DateTime.now();
      final isStale = now.difference(cache.updatedAt) > _autoRefreshCooldown;
      final inFailureBackoff = _lastFetchFailureTime != null &&
          now.difference(_lastFetchFailureTime!) < _failureRetryCooldown;

      // 计划 8.3 决策表由 grade_refresh_policy 统一实现：
      // 新鲜期与失败退避期都只约束「自动」触发——处于退避期不请求，
      // 缓存新鲜时同样不请求；只有用户明确刷新才允许绕过时间退避。
      // 原实现把「不在退避期」也当成使用缓存的前提，于是「新鲜缓存 + 最近失败」
      // 反而落到了后台刷新分支，在退避期内照样发起网络请求。
      final decision = decideGradeLoad(
        hasCredibleCache: true,
        isFresh: !isStale,
        inFailureBackoff: inFailureBackoff,
        userInitiated: forceRefresh,
      );

      if (decision == GradeLoadDecision.cacheOnly) {
        setState(() {
          _grades = cache.grades;
          _lastUpdatedAt = cache.updatedAt;
          _pageState =
              _grades.isEmpty ? GradePageState.empty : GradePageState.content;
          _isInitialLoading = false;
          _isRefreshing = false;
        });
        return;
      }

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

    if (!await _ensureReadReady(
        allowInteractiveLogin: allowsInteractiveAcademicLogin(origin))) {
      if (mounted && _requestGeneration == gen) {
        _lastFetchFailureTime = DateTime.now();
        setState(() {
          _isInitialLoading = false;
          _isRefreshing = false;
          if (cache == null) _pageState = GradePageState.error;
          _errorMessage = _sessionMessage;
        });
      }
      return;
    }
    if (!mounted || _requestGeneration != gen) return;

    final result =
        await _eduProvider!.fetchGrades(_selectedYear, _selectedSemester);

    if (!mounted || _requestGeneration != gen) return;

    if (result.success && result.data != null) {
      _lastSuccessfulSyncTime = DateTime.now();
      _lastFetchFailureTime = null;

      final entry =
          _eduProvider!.getCachedGrades(_selectedYear, _selectedSemester);
      final oldGrades = _grades;
      final newGrades = result.data!;

      // 首次使用建立 baseline，不进行增量比对，不产生 NEW 徽章
      if (!hasCredibleBaseline) {
        setState(() {
          _grades = newGrades;
          _lastUpdatedAt = entry?.updatedAt ?? DateTime.now();
          _pageState =
              newGrades.isEmpty ? GradePageState.empty : GradePageState.content;
          _isInitialLoading = false;
          _isRefreshing = false;
          _errorMessage = null;
        });
        _prefetchGradeDetails(newGrades);
        if (_eduProvider?.academicCapabilities.supportsAcademicSituation ??
            true) {
          unawaited(_loadAcademicSituation(
              origin: GradeRefreshOrigin.automatic, forceRefresh: true));
        }
        return;
      }

      final diff = GradeDiff.compute(oldGrades, newGrades);

      // 异常减少保护：静默刷新时如果返回门数异常少于已知旧数据，保留旧缓存，防止接口异常冲掉数据
      if (oldGrades.isNotEmpty && newGrades.length < oldGrades.length) {
        setState(() {
          _isInitialLoading = false;
          _isRefreshing = false;
        });
        // 这条路径（首屏加载 / 重试 / 切学期）不携带用户确认，因此只提示、不覆盖；
        // 提示同样绑定本次返回的具体候选，避免之后用旧提示授权另一份结果。
        _rememberReductionWarning(
          diff.removed.length,
          _gradeReductionSignature(newGrades),
        );
        return;
      }

      if (diff.hasChanges && diff.added.isNotEmpty) {
        _newlyAddedGradeKeys.addAll(
          diff.added
              .map((g) => _scopedGradeKey(_selectedYear, _selectedSemester, g)),
        );
      }

      setState(() {
        _grades = newGrades;
        _lastUpdatedAt = entry?.updatedAt ?? DateTime.now();
        _pageState =
            newGrades.isEmpty ? GradePageState.empty : GradePageState.content;
        _isInitialLoading = false;
        _isRefreshing = false;
        _errorMessage = null;
      });
      _prefetchGradeDetails(newGrades);

      // 静默自动刷新不弹“已是最新”，仅在发现新成绩/变更时通知
      if (diff.hasChanges && mounted) {
        if (diff.added.isNotEmpty) {
          _showSnackBar('发现 ${diff.added.length} 门新成绩，学期绩点已更新');
        } else if (diff.changed.isNotEmpty) {
          _showSnackBar('${diff.changed.length} 门成绩发生变化，学期绩点已更新');
        }
      }

      // 联动刷新官方 GPA（后台静默进行，不阻塞成绩列表）
      if (_eduProvider?.academicCapabilities.supportsAcademicSituation ??
          true) {
        unawaited(_loadAcademicSituation(
          origin: GradeRefreshOrigin.automatic, forceRefresh: true));
      }
    } else {
      _lastFetchFailureTime = DateTime.now();
      final errorMsg = result.errorMessage ?? '成绩加载失败';
      if (_academicSession?.isAuthenticated == false) {
        _sessionReadBlocked = true;
      }
      if (cache != null) {
        // 有效空缓存也属于已知数据，刷新失败时保留。
        setState(() {
          _isInitialLoading = false;
          _isRefreshing = false;
        });
        if (mounted) _showSnackBar('暂时无法刷新，当前展示上次同步结果');
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

  Future<List<EduGrade>?> _refreshGrades({
    required GradeRefreshOrigin origin,
  }) async {
    // 「是否静默」由来源唯一决定，不再由调用方各传一个 bool 互相漂移。
    final silent = gradeOriginIsSilent(origin);
    if (_isInitialLoading || _isRefreshing) return null;
    if (_eduProvider == null) return null;

    final hasCredibleBaseline =
        _eduProvider!.getCachedGrades(_selectedYear, _selectedSemester) !=
                null ||
            _grades.isNotEmpty;

    setState(() => _isRefreshing = true);

    final gen = ++_requestGeneration;
    if (!await _ensureReadReady(
        allowInteractiveLogin: allowsInteractiveAcademicLogin(origin))) {
      if (mounted && _requestGeneration == gen) {
        _lastFetchFailureTime = DateTime.now();
        setState(() {
          _isRefreshing = false;
          _errorMessage = _sessionMessage;
        });
      }
      return null;
    }
    if (!mounted || _requestGeneration != gen) return null;

    // 计划 8.2：三项权限必须分离。这里是「是否允许减少后的结果覆盖可信基线」。
    // 它**不能**由 silent=false 或 forceRefresh=true 顺带授予：
    // 自动 / 前台恢复（silent）永远不允许；用户明确刷新也只有在
    // 「上一次已经提示过减少、且上下文未变」时才算确认（计划 8.5）。
    // 静默刷新不消费确认：确认必须由用户明确的刷新动作消耗，
    // 否则一次后台刷新就会把待用户确认的减少悄悄转成覆盖授权。
    final pendingReductionSignature =
        silent ? null : _consumeReductionConfirmation();
    final allowReducedCount = allowReducedGradeOverwrite(
      silent: silent,
      userConfirmedReduction: pendingReductionSignature != null,
    );

    final result = await _eduProvider!.fetchGrades(
      _selectedYear,
      _selectedSemester,
      allowReducedCount: allowReducedCount,
      approvedReductionSignature: pendingReductionSignature,
    );

    if (!mounted || _requestGeneration != gen) {
      // 页面已切换或用户变化 → 视为失败
      return null;
    }

    if (result.success && result.data != null) {
      _lastSuccessfulSyncTime = DateTime.now();
      _lastFetchFailureTime = null;

      final entry =
          _eduProvider!.getCachedGrades(_selectedYear, _selectedSemester);
      final oldGrades = _grades;
      final newGrades = result.data!;

      if (!hasCredibleBaseline) {
        setState(() {
          _grades = newGrades;
          _lastUpdatedAt = entry?.updatedAt ?? DateTime.now();
          _pageState =
              newGrades.isEmpty ? GradePageState.empty : GradePageState.content;
          _isRefreshing = false;
          // 计划 8.6：成功路径必须清除对应错误，否则加载成功后页面仍停在 error 提示上。
          _errorMessage = null;
        });
        _prefetchGradeDetails(newGrades);
        if (mounted && !silent) {
          _showSnackBar('已是最新 · 刚刚同步');
        }
        if (_eduProvider?.academicCapabilities.supportsAcademicSituation ??
            true) {
          unawaited(_loadAcademicSituation(
              origin: GradeRefreshOrigin.automatic, forceRefresh: true));
        }
        return newGrades;
      }

      final diff = GradeDiff.compute(oldGrades, newGrades);

      // 减少保护必须在这里也成立：provider 只保证不把减少后的结果写进磁盘基线，
      // 内存列表由页面负责，否则一次未确认的自动/静默刷新仍会把页面上的可信结果冲掉。
      if (oldGrades.isNotEmpty && newGrades.length < oldGrades.length) {
        // 确认必须绑定「用户当时看到的那份具体结果」：重新请求后结果若再次变化
        //（例如 20 -> 19 的提示之后又返回 0），旧确认一律作废，必须按新结果重新提示。
        final candidateSignature = _gradeReductionSignature(newGrades);
        final reductionConfirmedByUser = allowReducedCount &&
            pendingReductionSignature == candidateSignature;
        if (!reductionConfirmedByUser) {
          setState(() {
            _isRefreshing = false;
          });
          // 静默（前台恢复）刷新不打断用户，因此不提示、也不记录确认上下文：
          // 之后用户第一次手动刷新会先看到提示，第二次才真正确认覆盖。
          if (mounted && !silent) {
            _rememberReductionWarning(diff.removed.length, candidateSignature);
          }
          return null;
        }
      }

      if (diff.hasChanges && diff.added.isNotEmpty) {
        _newlyAddedGradeKeys.addAll(
          diff.added
              .map((g) => _scopedGradeKey(_selectedYear, _selectedSemester, g)),
        );
      }

      setState(() {
        _grades = newGrades;
        _lastUpdatedAt = entry?.updatedAt ?? DateTime.now();
        _pageState =
            newGrades.isEmpty ? GradePageState.empty : GradePageState.content;
        _isRefreshing = false;
        // 计划 8.6：手动重试成功后必须清除之前的错误提示。
        _errorMessage = null;
      });
      _prefetchGradeDetails(newGrades);

      if (mounted && !silent) {
        if (diff.hasChanges) {
          if (diff.added.isNotEmpty) {
            _showSnackBar('发现 ${diff.added.length} 门新成绩，学期绩点已更新');
          } else if (diff.changed.isNotEmpty) {
            _showSnackBar('${diff.changed.length} 门成绩发生变化，学期绩点已更新');
          } else if (diff.removed.isNotEmpty) {
            _showSnackBar('成绩已更新（减少 ${diff.removed.length} 门）');
          }
        } else {
          _showSnackBar('已是最新 · 刚刚同步');
        }
      }

      // 联动刷新官方 GPA（后台静默进行，不阻塞成绩列表）
      if (_eduProvider?.academicCapabilities.supportsAcademicSituation ??
          true) {
        unawaited(_loadAcademicSituation(
          origin: GradeRefreshOrigin.automatic, forceRefresh: true));
      }

      return newGrades;
    }

    _lastFetchFailureTime = DateTime.now();
    setState(() {
      _isRefreshing = false;
      if (_academicSession?.isAuthenticated == false) {
        _sessionReadBlocked = true;
      }
    });
    if (mounted && !silent) _showSnackBar('刷新失败，请稍后重试');
    return null;
  }

  Future<bool> _refreshAcademicSituation({bool showMessage = true}) async {
    if (_isAcademicLoading) return false;
    await _loadAcademicSituation(
        origin: GradeRefreshOrigin.manual, forceRefresh: true);
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

  // 选择立即生效，网络恢复和失败反馈交给统一读取流程，避免抽屉静默停留。
  Future<bool> _switchSemester(String year, int semester) async {
    if (year == _selectedYear && semester == _selectedSemester) return true;
    if (_eduProvider == null) return false;
    final generation = ++_requestGeneration;
    // 切学期后成绩基线整体更换，旧的「减少确认」不再适用，必须作废重新提示。
    _reductionConfirmation.reset();
    setState(() {
      _selectedYear = year;
      _selectedSemester = semester;
      _grades = [];
      _newlyAddedGradeKeys.clear();
      _lastUpdatedAt = null;
      _activeFilter = '全部';
      _errorMessage = null;
      _isInitialLoading = true;
      _isRefreshing = false;
      _pageState = GradePageState.loading;
    });
    _saveSelectedSemester(year, semester);
    // 先让抽屉关闭，再允许恢复流程弹出教务登录框。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _requestGeneration) {
        unawaited(_loadGrades(origin: GradeRefreshOrigin.manual));
      }
    });
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
        onRefreshGrades:
            () => _refreshGrades(origin: GradeRefreshOrigin.manual),
        academicSituation: _academicSituation,
        academicUnavailableMessage: _eduProvider?.isUsingLocalAcademicSession ==
                    true &&
                !_eduProvider!.academicCapabilities.supportsAcademicSituation
            ? '当前教务身份暂未开放官方 GPA'
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
        if (_showsSessionNotice)
          GradeSessionNotice(
            message: _sessionMessage,
            onAction: () => _refreshGrades(origin: GradeRefreshOrigin.manual),
          ),
        Expanded(
          child: IndexedStack(
            index: _section.index,
            children: [
              RefreshIndicator(
                onRefresh: () =>
                    _refreshGrades(origin: GradeRefreshOrigin.manual),
                child: CustomScrollView(
                  key: const ValueKey('grade_term_scroll_view'),
                  controller: _termScrollController,
                  slivers: _buildTermContent(),
                ),
              ),
              RefreshIndicator(
                onRefresh: _refreshAcademicOverview,
                child: CustomScrollView(
                  key: const ValueKey('grade_overview_scroll_view'),
                  controller: _overviewScrollController,
                  slivers: _buildAcademicContent(),
                ),
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
      // 切到总览只是浏览动作：会话失效时保留空态提示，不得为此弹登录框。
      unawaited(_loadAcademicSituation(origin: GradeRefreshOrigin.automatic));
    }
    if (_creditRequirements == null &&
        _requirementError == null &&
        !_isRequirementLoading) {
      unawaited(
          _loadCreditRequirements(origin: GradeRefreshOrigin.automatic));
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
        _academicError = '当前教务身份暂未开放官方 GPA';
      }
      if (!capabilities.supportsCreditRequirements) {
        _creditRequirements = null;
        _isRequirementLoading = false;
        _requirementError = '当前教务身份暂未开放学分要求';
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
      // 官方学业概览卡片（提升至学业总览顶部）
      SliverToBoxAdapter(
        child: AcademicSituationCard(
          situation: _academicSituation,
          isLoading: _isAcademicLoading && _academicSituation == null,
          isRefreshing: _isAcademicLoading && _academicSituation != null,
          errorMessage: _eduProvider?.isUsingLocalAcademicSession == true &&
                  !_eduProvider!.academicCapabilities.supportsAcademicSituation
              ? '当前教务身份暂未开放官方 GPA'
              : (_academicError != null ? '暂未获取到官方学业概览' : null),
          updatedAt: _academicUpdatedAt,
          onRetry: () => _loadAcademicSituation(
              origin: GradeRefreshOrigin.manual, forceRefresh: true),
        ),
      ),

      // 学分要求模块
      SliverToBoxAdapter(
        child: AcademicRequirementOverview(
          requirements: _creditRequirements,
          isLoading: _isRequirementLoading,
          isBackgroundRefresh:
              _isRequirementLoading && _creditRequirements != null,
          errorMessage: _requirementError,
          hasCache: _creditRequirements != null,
          onRetry: () => _loadCreditRequirements(
              origin: GradeRefreshOrigin.manual, forceRefresh: true),
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
          hasValidData: _pageState == GradePageState.content ||
              _pageState == GradePageState.empty,
          updatedAt: _lastUpdatedAt,
          isRefreshing: _isRefreshing,
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
            onRetry: () => _loadGrades(origin: GradeRefreshOrigin.manual),
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
                    isNew: _newlyAddedGradeKeys.contains(
                      _scopedGradeKey(_selectedYear, _selectedSemester, grade),
                    ),
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
