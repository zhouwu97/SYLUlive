import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../platform/contracts/external_navigator.dart';

import '../../config/beta_release_policy.dart';
import '../../models/agent_context.dart';
import '../../models/competition.dart';
import '../../models/competition_dashboard_summary.dart';
import '../../providers/auth_provider.dart';
import '../../services/ai_assistant_service.dart';
import '../../services/domain_change_bus.dart';
import '../../utils/app_feedback.dart';
import '../../utils/competition_batch_action_payload.dart';
import '../../widgets/competition/competition_empty_state.dart';
import '../../widgets/competition/competition_match_reason_sheet.dart';
import '../../widgets/competition/competition_module_theme.dart';
import '../../widgets/competition/competition_profile_compact_card.dart';
import '../../widgets/competition/competition_status_helper.dart';
import '../../widgets/competition/competition_student_event_card.dart';
import '../../widgets/competition/competition_ui_tokens.dart';
import '../../widgets/competition/my_competition_plan_card.dart';
import '../../widgets/competition/competition_batch_selection_bar.dart';
import '../../widgets/competition/competition_batch_confirm_dialog.dart';
import '../../widgets/competition/competition_batch_action_sheet.dart';
import 'competition_calendar_item_detail_screen.dart';
import 'competition_my_hub_screen.dart';

import 'competition_admin_center_screen.dart';
import '../ai/ai_assistant_screen.dart';

class CompetitionCenterScreen extends StatefulWidget {
  const CompetitionCenterScreen({super.key});

  @override
  State<CompetitionCenterScreen> createState() =>
      _CompetitionCenterScreenState();
}

class _CompetitionCenterScreenState extends State<CompetitionCenterScreen> {
  static const int _pageSize = 20;

  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  late Dio _dio;
  List<CompetitionCategory> _categories = [];
  List<CompetitionEvent> _events = [];
  List<CompetitionCandidateGroup> _candidateGroups = [];
  CompetitionCatalogSummary _candidateCatalog =
      const CompetitionCatalogSummary();
  final Set<int> _joinedEventIds = {};
  final Set<int> _addingEventIds = {};
  Timer? _searchDebounce;
  bool _categoriesLoading = true;
  bool _overviewLoading = true;
  bool _eventsLoading = true;
  bool _stateLoading = false;
  bool _loadingMore = false;
  String? _categoriesError;
  String? _overviewError;
  String? _eventsError;
  String? _stateError;
  int _deadlineSoonCount = 0;
  int _eventTotal = 0;
  int _currentPage = 1;
  int _requestSerial = 0;
  int _dashboardRequestSerial = 0;
  int _stateRequestSerial = 0;
  bool _hasMore = false;
  bool _profileReady = false;
  String? _categorySlug;
  final Set<String> _recommendations = {};
  final Set<String> _recognitions = {};
  final Set<String> _sources = {};
  int? _calendarCount;
  CompetitionDashboardSummary? _competitionDashboard;
  bool _dashboardLoading = false;
  String? _dashboardError;
  int? _sessionGeneration;

  String _studentFocusFilter = 'all';

  @override
  void initState() {
    super.initState();
    DomainChangeBus.instance.addListener(_handleDomainChange);
    _dio = context.read<AuthProvider>().dio;
    _searchController.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    _loadAll();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final generation = context.watch<AuthProvider>().sessionGeneration;
    if (_sessionGeneration == null) {
      _sessionGeneration = generation;
    } else if (_sessionGeneration != generation) {
      _sessionGeneration = generation;
      _dashboardRequestSerial++;
      _stateRequestSerial++;
      _competitionDashboard = null;
      _dashboardError = null;
      _calendarCount = null;
      _profileReady = false;
      _joinedEventIds.clear();
      _loadUserState();
      _loadCompetitionDashboard();
    }
  }

  @override
  void dispose() {
    DomainChangeBus.instance.removeListener(_handleDomainChange);
    _searchDebounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _handleDomainChange() {
    if (!mounted ||
        DomainChangeBus.instance.lastChange != DomainChange.competitionPlan) {
      return;
    }
    unawaited(_loadUserState());
    unawaited(_loadCompetitionDashboard());
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadCategories(),
      _loadOverview(),
      _loadEvents(reset: true),
      _loadUserState(),
      _loadCompetitionDashboard(),
    ]);
  }

  Future<void> _loadCompetitionDashboard() async {
    final request = ++_dashboardRequestSerial;
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      if (mounted) {
        setState(() {
          _competitionDashboard = null;
          _dashboardLoading = false;
          _dashboardError = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _dashboardLoading = true;
        _dashboardError = null;
      });
    }
    try {
      final response = await auth.dio.get('/user/competitions/dashboard');
      if (!mounted || request != _dashboardRequestSerial) return;
      setState(() {
        _competitionDashboard = CompetitionDashboardSummary.fromJson(
          Map<String, dynamic>.from(response.data as Map),
        );
        _dashboardLoading = false;
      });
    } catch (error) {
      if (!mounted || request != _dashboardRequestSerial) return;
      setState(() {
        _dashboardLoading = false;
        _dashboardError = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '竞赛档案加载失败')
            : '竞赛档案数据解析失败';
      });
    }
  }

  void _onSearchChanged() {
    if (mounted) setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      _loadEvents(reset: true);
    });
  }

  void _submitSearch() {
    _searchDebounce?.cancel();
    _loadEvents(reset: true);
  }

  void _onScroll() {
    if (_scrollController.position.extentAfter < 320 &&
        _hasMore &&
        !_eventsLoading &&
        !_loadingMore) {
      _loadEvents(reset: false);
    }
  }

  Future<void> _loadCategories() async {
    if (mounted) {
      setState(() {
        _categoriesLoading = true;
        _categoriesError = null;
      });
    }
    try {
      final response = await _dio.get('/competitions/categories');
      if (!mounted) return;
      setState(() {
        _categories = ((response.data as List?) ?? [])
            .map((e) => CompetitionCategory.fromJson(e))
            .toList();
        _categoriesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _categoriesLoading = false;
        _categoriesError = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '分类加载失败')
            : '分类数据解析失败';
      });
    }
  }

  Future<void> _loadOverview() async {
    if (mounted) {
      setState(() {
        _overviewLoading = true;
        _overviewError = null;
      });
    }
    try {
      final response = await _dio.get('/competitions/overview');
      final data = Map<String, dynamic>.from(response.data as Map);
      if (!mounted) return;
      setState(() {
        _deadlineSoonCount =
            (data['deadline_soon_count'] as num?)?.toInt() ?? 0;
        _overviewLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _overviewLoading = false;
        _overviewError = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '统计加载失败')
            : '统计数据解析失败';
      });
    }
  }

  Future<void> _loadUserState() async {
    final request = ++_stateRequestSerial;
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      if (mounted) {
        setState(() {
          _calendarCount = null;
          _profileReady = false;
          _stateError = null;
          _joinedEventIds.clear();
        });
      }
      return;
    }
    if (mounted) setState(() => _stateLoading = true);
    try {
      final response = await _dio.get('/user/competitions/state');
      final data = Map<String, dynamic>.from(response.data as Map);
      final joined = ((data['joined_event_ids'] as List?) ?? []).map(
        (value) => (value as num).toInt(),
      );
      if (!mounted || request != _stateRequestSerial) return;
      setState(() {
        _calendarCount = (data['calendar_count'] as num?)?.toInt() ?? 0;
        _profileReady = data['profile_ready'] == true;
        _joinedEventIds
          ..clear()
          ..addAll(joined);
        _stateLoading = false;
        _stateError = null;
        if (!_profileReady && _studentFocusFilter == 'fit') {
          _studentFocusFilter = 'all';
        }
      });
    } catch (error) {
      if (mounted && request == _stateRequestSerial) {
        setState(() {
          _stateLoading = false;
          _stateError = error is DioException
              ? AppFeedback.dioErrorMessage(error, fallback: '计划状态加载失败')
              : '计划状态解析失败';
        });
      }
    }
  }

  Future<void> _loadEvents({required bool reset}) async {
    final request = ++_requestSerial;
    final nextPage = reset ? 1 : _currentPage + 1;
    if (mounted) {
      setState(() {
        if (reset) {
          _eventsLoading = true;
          _eventsError = null;
          _events = [];
          _candidateGroups = [];
        } else {
          _loadingMore = true;
        }
      });
    }
    try {
      final isFit = _studentFocusFilter == 'fit';
      final response = await _dio.get(
        isFit ? '/user/competitions/candidates' : '/competitions/events',
        queryParameters: {
          ..._queryParams(),
          'page': nextPage,
          'page_size': _pageSize,
        },
      );
      final data = Map<String, dynamic>.from(response.data as Map);
      final candidateGroups = isFit
          ? ((data['groups'] as List?) ?? const [])
              .whereType<Map>()
              .map(
                (group) => CompetitionCandidateGroup.fromJson(
                  Map<String, dynamic>.from(group),
                ),
              )
              .toList(growable: false)
          : const <CompetitionCandidateGroup>[];
      final items = isFit
          ? candidateGroups.expand((group) => group.items).toList()
          : ((data['items'] as List?) ?? [])
              .map(
                (item) => CompetitionEvent.fromJson(
                  Map<String, dynamic>.from(item as Map),
                ),
              )
              .toList();
      final total = (data['total'] as num?)?.toInt() ?? items.length;
      if (!mounted || request != _requestSerial) return;
      setState(() {
        if (reset) {
          _events = items;
          _candidateGroups = candidateGroups;
        } else {
          final byId = {for (final event in _events) event.id: event};
          for (final event in items) {
            byId[event.id] = event;
          }
          _events = byId.values.toList();
          if (isFit) {
            _candidateGroups = _mergeCandidateGroups(
              _candidateGroups,
              candidateGroups,
            );
          }
        }
        if (!isFit) {
          _candidateGroups = [];
        } else {
          _candidateCatalog = CompetitionCatalogSummary.fromJson(
            data['catalog'] is Map
                ? Map<String, dynamic>.from(data['catalog'] as Map)
                : null,
          );
          _profileReady = data['profile_ready'] == true;
        }
        _eventTotal = total;
        _currentPage = nextPage;
        // 服务端返回不足一页即视为到底。只比较 total 会在跨页重复项出现时失效：
        // 去重后的 _events.length 永远追不上 total，滚动到底会无限翻页空转。
        _hasMore = items.length >= _pageSize && _events.length < total;
        _eventsLoading = false;
        _loadingMore = false;
        _eventsError = null;
      });
    } catch (error) {
      if (!mounted || request != _requestSerial) return;
      setState(() {
        _eventsLoading = false;
        _loadingMore = false;
        _eventsError = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '比赛加载失败')
            : '比赛数据解析失败';
      });
    }
  }

  List<CompetitionCandidateGroup> _mergeCandidateGroups(
    List<CompetitionCandidateGroup> current,
    List<CompetitionCandidateGroup> incoming,
  ) {
    final order = <String>[
      'major_match',
      'college_match',
      'general_match',
    ];
    final byKey = <String, CompetitionCandidateGroup>{
      for (final group in current) group.key: group,
    };
    for (final group in incoming) {
      final previous = byKey[group.key];
      final items = <int, CompetitionEvent>{
        for (final item in previous?.items ?? const <CompetitionEvent>[])
          item.id: item,
      };
      for (final item in group.items) {
        items[item.id] = item;
      }
      byKey[group.key] = CompetitionCandidateGroup(
        key: group.key,
        label: group.label,
        count: group.count,
        items: items.values.toList()
          ..sort((a, b) => a.ruleOrder.compareTo(b.ruleOrder)),
      );
    }
    return [
      for (final key in order)
        if (byKey[key] != null) byKey[key]!,
    ];
  }

  Map<String, dynamic> _queryParams() {
    final params = <String, dynamic>{
      if (_searchController.text.trim().isNotEmpty)
        'keyword': _searchController.text.trim(),
      if (_categorySlug != null) 'category_slug': _categorySlug,
      if (BetaReleasePolicy.competitionRecommendations &&
          _recommendations.isNotEmpty)
        'recommendation_level': _recommendations.join(','),
      if (_recognitions.isNotEmpty)
        'school_recognition_status': _recognitions.join(','),
      if (_sources.isNotEmpty) 'source_channel': _sources.join(','),
    };

    switch (_studentFocusFilter) {
      case 'recommended':
        if (BetaReleasePolicy.competitionRecommendations &&
            _recommendations.isEmpty) {
          params['recommendation_level'] = 'S,A,B+';
        }
        break;
      case 'deadline':
        params['date_status'] = 'deadline_soon';
        break;
      case 'recognized':
        if (_recognitions.isEmpty) {
          params['school_recognition_status'] = 'recognized';
        }
        break;
      case 'fit':
        break;
      case 'pending':
        params['date_status'] = 'time_pending';
        break;
    }
    return params;
  }

  void _resetFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _searchDebounce?.cancel();
    setState(() {
      _categorySlug = null;
      _recommendations.clear();
      _recognitions.clear();
      _sources.clear();
      _studentFocusFilter = 'all';
    });
    _loadEvents(reset: true);
  }

  String get _filterSummary {
    final parts = <String>[];
    if (_categorySlug != null) {
      final category = _categories
          .where((item) => item.slug == _categorySlug)
          .cast<CompetitionCategory?>()
          .firstOrNull;
      if (category != null) parts.add(category.name);
    }
    if (BetaReleasePolicy.competitionRecommendations) {
      parts.addAll(_recommendations.map((e) => '$e推荐'));
    }
    parts.addAll(_recognitions.map(competitionRecognitionLabel));
    parts.addAll(_sources.map(_sourceLabel));
    if (parts.isEmpty) return '全部比赛';
    if (parts.length <= 3) return parts.join(' · ');
    return '已选 ${parts.length} 项';
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final isAdmin = user?.isAdmin == true || user?.isSuperAdmin == true;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);

    return Theme(
      data: CompetitionModuleTheme.of(context),
      child: Scaffold(
        backgroundColor: pageBg,
        appBar: AppBar(
          backgroundColor: pageBg,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          title: const Text(
            '竞赛中心',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          actions: [
            if (isAdmin)
              TextButton.icon(
                onPressed: _openAdminCenter,
                icon: const Icon(Icons.admin_panel_settings_rounded, size: 18),
                label: const Text('管理'),
                style: TextButton.styleFrom(
                  foregroundColor: CompetitionUiTokens.accent(isDark),
                ),
              ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _loadAll,
          child: ListView(
            controller: _scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 32),
            children: _buildStudentHome(isDark),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildStudentHome(bool isDark) {
    return [
      _buildSearchAndFilters(isDark),
      _buildStudentOverview(isDark),
      CompetitionProfileCompactCard(
        isLoggedIn: context.watch<AuthProvider>().isLoggedIn,
        summary: _competitionDashboard,
        loading: _dashboardLoading,
        error: _dashboardError,
        onTap: _openCompetitionHub,
        onRetry: _loadCompetitionDashboard,
      ),
      _buildStudentFocusTabs(isDark),
      if (_studentFocusFilter == 'fit') _buildCandidateNotice(isDark),
      _buildSectionTitle(
        title: _studentFocusTitle,
        subtitle: _eventsLoading
            ? '正在加载比赛'
            : '共 $_eventTotal 个结果 · ${_filterSummary == '全部比赛' ? '全部分类' : _filterSummary}',
        isDark: isDark,
      ),
      _buildEventList(isAdmin: false, isDark: isDark),
    ];
  }

  Widget _buildSearchAndFilters(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        0,
        CompetitionUiTokens.pagePadding,
        12,
      ),
      child: Column(
        children: [
          Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: CompetitionUiTokens.cardBg(isDark),
              borderRadius: BorderRadius.circular(
                CompetitionUiTokens.cardRadius,
              ),
              border: Border.all(
                color: CompetitionUiTokens.borderColor(isDark),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.search_rounded,
                  color: CompetitionUiTokens.subColor(isDark),
                  size: 21,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _submitSearch(),
                    decoration: InputDecoration(
                      hintText: '搜索比赛 / 专业方向 / 标签',
                      hintStyle: TextStyle(
                        color: CompetitionUiTokens.subColor(isDark),
                        fontSize: 14,
                      ),
                      border: InputBorder.none,
                      isCollapsed: true,
                    ),
                    style: TextStyle(
                      fontSize: 14,
                      color: CompetitionUiTokens.titleColor(isDark),
                    ),
                  ),
                ),
                if (_searchController.text.isNotEmpty)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      _searchController.clear();
                      _submitSearch();
                    },
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: CompetitionUiTokens.subColor(isDark),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildSoftButton(
                icon: Icons.tune_rounded,
                label: _categoriesLoading ? '分类…' : '分类',
                isDark: isDark,
                highlight: _filterSummary != '全部比赛',
                onTap: _openFilters,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _filterSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _filterSummary == '全部比赛'
                        ? CompetitionUiTokens.subColor(isDark)
                        : CompetitionUiTokens.accent(isDark),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_filterSummary != '全部比赛' ||
                  _searchController.text.trim().isNotEmpty)
                TextButton(onPressed: _resetFilters, child: const Text('重置')),
            ],
          ),
          if (_categoriesError != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _loadCategories,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: Text(_categoriesError!),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStudentOverview(bool isDark) {
    final isLoggedIn = context.watch<AuthProvider>().isLoggedIn;
    final planValue = !isLoggedIn
        ? '登录后使用'
        : _stateError != null
            ? '重试'
            : (_stateLoading && _calendarCount == null)
                ? '—'
                : '${_calendarCount ?? 0}';
    final deadlineValue = _overviewLoading
        ? '—'
        : _overviewError != null
            ? '重试'
            : '$_deadlineSoonCount';
    return _buildStatBand(isDark, [
      (
        '我的计划',
        planValue,
        () {
          if (_stateError != null) {
            _loadUserState();
            return;
          }
          _openCalendar();
        },
      ),
      (
        '14天内截止',
        deadlineValue,
        () {
          if (_overviewError != null) {
            _loadOverview();
            return;
          }
          setState(() => _studentFocusFilter = 'deadline');
          _loadEvents(reset: true);
        },
      ),
    ]);
  }

  Future<void> _openCompetitionHub() async {
    var auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      await Navigator.pushNamed(context, '/login');
      if (!mounted) return;
      auth = context.read<AuthProvider>();
      if (!auth.isLoggedIn) return;
    }
    final accountID = auth.user?.id;
    if (accountID == null) return;
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            CompetitionMyHubScreen(dio: auth.dio, accountKey: accountID),
      ),
    );
    if (!mounted || context.read<AuthProvider>().user?.id != accountID) return;
    await Future.wait([_loadCompetitionDashboard(), _loadUserState()]);
    if (result == 'fit' && BetaReleasePolicy.competitionCandidateMatching) {
      setState(() => _studentFocusFilter = 'fit');
      await _loadEvents(reset: true);
      return;
    }
    if (mounted && _studentFocusFilter == 'fit') {
      await _loadEvents(reset: true);
    }
  }

  Widget _buildStatBand(
    bool isDark,
    List<(String, String, VoidCallback?)> items,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        0,
        CompetitionUiTokens.pagePadding,
        14,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: CompetitionUiTokens.cardDecoration(isDark),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              Expanded(
                child: InkWell(
                  onTap: items[i].$3,
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    children: [
                      Text(
                        items[i].$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: items[i].$2.length > 4 ? 14 : 18,
                          fontWeight: FontWeight.w900,
                          color: CompetitionUiTokens.titleColor(isDark),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        items[i].$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: CompetitionUiTokens.subColor(isDark),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (i != items.length - 1)
                Container(
                  width: 1,
                  height: 30,
                  color: CompetitionUiTokens.borderColor(isDark),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStudentFocusTabs(bool isDark) {
    final isLoggedIn = context.watch<AuthProvider>().isLoggedIn;
    final tabs = [
      ('all', '全部'),
      if (BetaReleasePolicy.competitionCandidateMatching && isLoggedIn)
        ('fit', '适合我'),
      ('deadline', '临近截止'),
      ('recognized', '学校认定'),
      ('pending', '时间待公布'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        0,
        CompetitionUiTokens.pagePadding,
        14,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var index = 0; index < tabs.length; index++) ...[
              SizedBox(
                height: 34,
                child: ChoiceChip(
                  label: Text(tabs[index].$2),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 7),
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  visualDensity: const VisualDensity(vertical: -2),
                  selected: _studentFocusFilter == tabs[index].$1,
                  onSelected: (_) {
                    setState(() => _studentFocusFilter = tabs[index].$1);
                    _loadEvents(reset: true);
                  },
                  selectedColor: CompetitionUiTokens.accent(isDark),
                  backgroundColor: CompetitionUiTokens.cardBg(isDark),
                  side: BorderSide(
                    color: _studentFocusFilter == tabs[index].$1
                        ? CompetitionUiTokens.accent(isDark)
                        : CompetitionUiTokens.borderColor(isDark),
                  ),
                  labelStyle: TextStyle(
                    color: _studentFocusFilter == tabs[index].$1
                        ? Colors.white
                        : CompetitionUiTokens.titleColor(isDark),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                  showCheckmark: false,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              if (index != tabs.length - 1) const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCandidateNotice(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        0,
        CompetitionUiTokens.pagePadding,
        14,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: CompetitionUiTokens.accentSoft(isDark),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 18,
              color: CompetitionUiTokens.accent(isDark),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _profileReady
                        ? '根据专业、资格和目标筛出 $_eventTotal 项候选'
                        : '完善教务身份后可生成匹配候选',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: CompetitionUiTokens.titleColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '当前为候选解释，不代表获奖概率',
                    style: TextStyle(
                      fontSize: 12,
                      color: CompetitionUiTokens.subColor(isDark),
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _openCandidateBasis,
              child: const Text('查看依据'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle({
    required String title,
    required String subtitle,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        CompetitionUiTokens.pagePadding,
        2,
        CompetitionUiTokens.pagePadding,
        12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 13,
              color: CompetitionUiTokens.subColor(isDark),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventList({required bool isAdmin, required bool isDark}) {
    if (_eventsLoading && _events.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 40),
        child: Center(
          child: CircularProgressIndicator(
            color: CompetitionUiTokens.accent(isDark),
          ),
        ),
      );
    }
    if (_events.isEmpty) {
      if (_eventsError != null) {
        return CompetitionEmptyState(
          title: '比赛加载失败',
          message: _eventsError!,
          primaryText: '重试',
          onPrimaryTap: () => _loadEvents(reset: true),
          secondaryText: '刷新全部',
          onSecondaryTap: _loadAll,
        );
      }
      return CompetitionEmptyState(
        title: isAdmin ? '列表还没有内容' : '暂时没有符合条件的比赛',
        message: isAdmin ? '可以 AI 导入或手动新建官方草稿。' : '换一个筛选条件看看，或先导入同学整理的计划。',
        primaryText: '导入计划',
        onPrimaryTap: _openShareImport,
        secondaryText: '刷新',
        onSecondaryTap: () => _loadEvents(reset: true),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: CompetitionUiTokens.pagePadding,
      ),
      child: Column(
        children: [
          if (_studentFocusFilter == 'fit' && _candidateGroups.isNotEmpty)
            for (final group in _candidateGroups) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 4, 2, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${group.label} · ${group.count}项',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: CompetitionUiTokens.titleColor(isDark),
                    ),
                  ),
                ),
              ),
              ...group.items.map((event) => _buildEventCard(event, isAdmin)),
              const SizedBox(height: 4),
            ]
          else
            ..._events.map((e) => _buildEventCard(e, isAdmin)),
          if (_loadingMore)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: CircularProgressIndicator(
                color: CompetitionUiTokens.accent(isDark),
              ),
            ),
          if (_eventsError != null && _events.isNotEmpty)
            TextButton.icon(
              onPressed: () => _loadEvents(reset: false),
              icon: const Icon(Icons.refresh_rounded),
              label: Text('下一页加载失败，点击重试：$_eventsError'),
            ),
        ],
      ),
    );
  }

  String get _studentFocusTitle {
    switch (_studentFocusFilter) {
      case 'deadline':
        return '临近截止';
      case 'recognized':
        return '学校认定';
      case 'fit':
        return '适合我';
      case 'pending':
        return '时间待公布';
      case 'recommended':
        return '推荐关注';
      default:
        return '比赛目录';
    }
  }

  // 已移除头图、导入按钮、统计项、搜索框和筛选栏

  Widget _buildEventCard(CompetitionEvent event, bool isAdmin) {
    return CompetitionStudentEventCard(
      event: event,
      onTap: () {
        _openDetail(event);
      },
      joined: _joinedEventIds.contains(event.id),
      isAdding: _addingEventIds.contains(event.id),
      onAddPlan: () => _copyToCalendar(event.id),
      onJoinedTap: _openCalendar,
      onWhyTap: event.coreReason.trim().isEmpty
          ? null
          : () => showCompetitionMatchReasonSheet(context, event),
      showRecommendations: false,
    );
  }

  void _openCandidateBasis() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          decoration: BoxDecoration(
            color: CompetitionUiTokens.pageBg(isDark),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '候选筛选依据',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              const Text(
                '候选由服务端按发布状态、参赛资格、专业和学院范围筛选。'
                '当前目录不允许画像改变顺序，也不开放强推荐。',
                style: TextStyle(height: 1.55),
              ),
              const SizedBox(height: 12),
              Text(
                '目录版本：${_candidateCatalog.datasetVersion}',
                style: TextStyle(color: CompetitionUiTokens.subColor(isDark)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSoftButton({
    required IconData icon,
    required String label,
    required bool isDark,
    required bool highlight,
    required VoidCallback onTap,
  }) {
    return Material(
      color: highlight
          ? CompetitionUiTokens.titleColor(isDark)
          : Colors.transparent,
      shape: StadiumBorder(
        side: BorderSide(
          color: highlight
              ? Colors.transparent
              : CompetitionUiTokens.borderColor(isDark),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 16,
                color: highlight
                    ? CompetitionUiTokens.pageBg(isDark)
                    : CompetitionUiTokens.titleColor(isDark),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: highlight ? FontWeight.w600 : FontWeight.normal,
                  color: highlight
                      ? CompetitionUiTokens.pageBg(isDark)
                      : CompetitionUiTokens.titleColor(isDark),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyToCalendar(int eventId) async {
    final auth = context.read<AuthProvider>();
    if (!auth.isLoggedIn) {
      await Navigator.pushNamed(context, '/login');
      if (!mounted || !context.read<AuthProvider>().isLoggedIn) return;
      await _loadUserState();
    }
    if (_joinedEventIds.contains(eventId) ||
        _addingEventIds.contains(eventId)) {
      await _openCalendar();
      return;
    }
    setState(() => _addingEventIds.add(eventId));
    try {
      final response = await _dio.post(
        '/user/competition-calendar/items/copy-from-official/$eventId',
      );
      if (!mounted) return;
      final alreadyExists = response.data is Map &&
          (response.data as Map)['already_exists'] == true;
      setState(() {
        _joinedEventIds.add(eventId);
        if (!alreadyExists) {
          _calendarCount = (_calendarCount ?? 0) + 1;
        }
      });
      DomainChangeBus.instance.emit(DomainChange.competitionPlan);
      AppFeedback.showSnackBar(
        context,
        alreadyExists ? '比赛已在我的计划中' : '已加入我的竞赛计划',
      );
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '加入失败，请先登录'),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _addingEventIds.remove(eventId));
    }
  }

  Future<void> _openDetail(CompetitionEvent event) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CompetitionDetailScreen(eventId: event.id),
      ),
    );
    if (mounted && context.read<AuthProvider>().isLoggedIn) {
      await _loadUserState();
    }
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<_CompetitionFilterResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CompetitionFilterSheet(
        categories: _categories,
        categorySlug: _categorySlug,
        recommendations: _recommendations,
        showRecommendations: BetaReleasePolicy.competitionRecommendations,
        recognitions: _recognitions,
        sources: _sources,
      ),
    );
    if (result == null) return;
    setState(() {
      _categorySlug = result.categorySlug;
      _recommendations
        ..clear()
        ..addAll(result.recommendations);
      _recognitions
        ..clear()
        ..addAll(result.recognitions);
      _sources
        ..clear()
        ..addAll(result.sources);
    });
    await _loadEvents(reset: true);
  }

  Future<void> _openCalendar() async {
    if (!context.read<AuthProvider>().isLoggedIn) {
      await Navigator.pushNamed(context, '/login');
      if (!mounted || !context.read<AuthProvider>().isLoggedIn) return;
      await _loadUserState();
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionCalendarScreen()),
    );
    if (mounted) await _loadUserState();
  }

  void _openShareImport() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionShareImportScreen()),
    );
  }

  Future<void> _openAdminCenter() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const CompetitionAdminCenterScreen()),
    );
  }
}

class CompetitionDetailScreen extends StatefulWidget {
  final int eventId;
  const CompetitionDetailScreen({super.key, required this.eventId});

  @override
  State<CompetitionDetailScreen> createState() =>
      _CompetitionDetailScreenState();
}

class _CompetitionDetailScreenState extends State<CompetitionDetailScreen> {
  CompetitionEvent? _event;
  Map<String, dynamic> _eventRaw = {};
  bool _loading = true;
  String? _error;
  bool _askingAgent = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dio = context.read<AuthProvider>().dio;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final resp = await dio.get('/competitions/events/${widget.eventId}');
      if (!mounted) return;
      setState(() {
        _eventRaw = Map<String, dynamic>.from(resp.data as Map);
        _event = CompetitionEvent.fromJson(_eventRaw);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is DioException
            ? AppFeedback.dioErrorMessage(error, fallback: '比赛详情加载失败')
            : '比赛详情解析失败';
      });
    }
  }

  Future<void> _addToPlan(CompetitionEvent event) async {
    try {
      await context.read<AuthProvider>().dio.post(
            '/user/competition-calendar/items/copy-from-official/${event.id}',
          );
      if (!mounted) return;
      DomainChangeBus.instance.emit(DomainChange.competitionPlan);
      AppFeedback.showSnackBar(context, '已加入我的计划');
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '加入失败，请先登录'),
        isError: true,
      );
    }
  }

  Future<void> _askAgent(CompetitionEvent event) async {
    if (_askingAgent) return;
    setState(() => _askingAgent = true);
    final dio = context.read<AuthProvider>().dio;
    try {
      final service = AiAssistantService(dio);
      final capabilities = await service.getCapabilities();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => AiAssistantScreen(
            capabilities: capabilities,
            service: service,
            dio: dio,
            initialPrompt: '我适合参加这个比赛吗？',
            launchContext: AgentLaunchContext(
              entrypoint: 'competition_detail',
              contextRefs: <AgentContextRef>[
                AgentContextRef(type: 'competition_event', id: '${event.id}'),
              ],
              suggestedIntent: '评估当前赛事是否适合我，并结合时间安排给出建议',
            ),
          ),
        ),
      );
    } on AiAssistantServiceException catch (error) {
      if (mounted) {
        AppFeedback.showSnackBar(context, error.message, isError: true);
      }
    } catch (_) {
      if (mounted) {
        AppFeedback.showSnackBar(context, '校园 Agent 暂不可用', isError: true);
      }
    } finally {
      if (mounted) setState(() => _askingAgent = false);
    }
  }

  String _rawValue(String key) => '${_eventRaw[key] ?? ''}'.trim();

  @override
  Widget build(BuildContext context) {
    final event = _event;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);
    final titleColor = CompetitionUiTokens.titleColor(isDark);

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: titleColor,
        title: Text('比赛详情', style: TextStyle(color: titleColor)),
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                color: CompetitionUiTokens.accent(isDark),
              ),
            )
          : _error != null
              ? ListView(
                  padding: const EdgeInsets.only(top: 24),
                  children: [
                    CompetitionEmptyState(
                      title: '比赛详情加载失败',
                      message: _error!,
                      primaryText: '重试',
                      onPrimaryTap: _load,
                      secondaryText: '返回',
                      onSecondaryTap: () => Navigator.maybePop(context),
                    ),
                  ],
                )
              : event == null
                  ? Center(
                      child: Text(
                        '比赛不存在',
                        style: TextStyle(
                            color: CompetitionUiTokens.subColor(isDark)),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _detailCard(
                          isDark: isDark,
                          children: [
                            Text(
                              event.title,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w900,
                                color: titleColor,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (BetaReleasePolicy
                                    .competitionRecommendations)
                                  _detailChip(
                                      '${event.recommendationLevel}推荐', isDark),
                                _detailChip(
                                  event.primaryCategory?.name ?? '未分类',
                                  isDark,
                                ),
                                _detailChip(
                                    _competitionTimeStateLabel(event), isDark),
                              ],
                            ),
                            if (BetaReleasePolicy.competitionRecommendations &&
                                event.recommendationReason.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(
                                event.recommendationReason,
                                style: TextStyle(
                                  color: CompetitionUiTokens.subColor(isDark),
                                  height: 1.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                        _detailCard(
                          title: '时间安排',
                          isDark: isDark,
                          children: [
                            _detailInfo(
                              _competitionTimeLine(event)?.label ?? '报名安排',
                              _competitionTimeLine(event)?.value ?? '时间待公布',
                              isDark,
                            ),
                            _detailInfo('比赛时间', event.eventTimeText, isDark),
                            _detailInfo(
                              '时间状态',
                              _competitionTimeStateLabel(event),
                              isDark,
                            ),
                            _detailInfo(
                                '时间精度', event.timePrecisionLabel, isDark),
                            _detailInfo('时间说明', event.timeNote, isDark),
                          ],
                        ),
                        _detailCard(
                          title: '参赛信息',
                          isDark: isDark,
                          children: [
                            _detailInfo(
                              '学校认定',
                              competitionRecognitionLabel(
                                event.schoolRecognitionStatus,
                              ),
                              isDark,
                            ),
                            _detailInfo(
                                '学校等级', event.schoolRecognitionGrade, isDark),
                            if (BetaReleasePolicy
                                .competitionRecommendations) ...[
                              _detailInfo(
                                  '推荐等级', event.recommendationLevel, isDark),
                              _detailInfo(
                                  '推荐理由', event.recommendationReason, isDark),
                            ],
                            _detailInfo(
                                '适合对象', _rawValue('target_audience'), isDark),
                            _detailInfo(
                              '参赛形式',
                              _rawValue('participation_type'),
                              isDark,
                            ),
                          ],
                        ),
                        _detailCard(
                          title: '基本信息',
                          isDark: isDark,
                          children: [
                            _detailInfo('主办方', event.organizer, isDark),
                            _detailInfo('比赛级别', event.competitionLevel, isDark),
                            _detailInfo(
                              '地点',
                              event.isOnline ? '线上' : event.location,
                              isDark,
                            ),
                            _detailInfo(
                              '来源',
                              _sourceLabel(event.sourceChannel),
                              isDark,
                            ),
                          ],
                        ),
                        _detailCard(
                          title: '比赛说明',
                          isDark: isDark,
                          children: [
                            Text(
                              (event.description.isNotEmpty
                                      ? event.description
                                      : event.summary)
                                  .trim(),
                              style: TextStyle(height: 1.6, color: titleColor),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: () => _addToPlan(event),
                          style: FilledButton.styleFrom(
                            backgroundColor: CompetitionUiTokens.accent(isDark),
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.add),
                          label: const Text('加入我的计划'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              _askingAgent ? null : () => _askAgent(event),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: titleColor,
                            side: BorderSide(
                              color: CompetitionUiTokens.borderColor(isDark),
                            ),
                          ),
                          icon: _askingAgent
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.auto_awesome_outlined),
                          label:
                              Text(_askingAgent ? '正在打开 Agent…' : '问问 Agent'),
                        ),
                        if (event.officialUrl.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () => ExternalNavigator.current().open(
                              Uri.parse(event.officialUrl),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: titleColor,
                              side: BorderSide(
                                color: CompetitionUiTokens.borderColor(isDark),
                              ),
                            ),
                            icon: const Icon(Icons.open_in_new),
                            label: const Text('打开官网'),
                          ),
                        if (event.noticeUrl.isNotEmpty)
                          OutlinedButton.icon(
                            onPressed: () => ExternalNavigator.current().open(
                              Uri.parse(event.noticeUrl),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: titleColor,
                              side: BorderSide(
                                color: CompetitionUiTokens.borderColor(isDark),
                              ),
                            ),
                            icon: const Icon(Icons.article_outlined),
                            label: const Text('查看通知'),
                          ),
                      ],
                    ),
    );
  }
}

Widget _detailCard({
  String? title,
  required bool isDark,
  required List<Widget> children,
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: CompetitionUiTokens.cardDecoration(isDark),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          const SizedBox(height: 10),
        ],
        ...children,
      ],
    ),
  );
}

Widget _detailChip(String label, bool isDark) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(
      color: CompetitionUiTokens.accentSoft(isDark),
      borderRadius: BorderRadius.circular(CompetitionUiTokens.chipRadius),
    ),
    child: Text(
      label,
      style: TextStyle(
        color: CompetitionUiTokens.accent(isDark),
        fontSize: 12,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

Widget _detailInfo(String label, String value, bool isDark) {
  if (value.trim().isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: TextStyle(
              color: CompetitionUiTokens.subColor(isDark),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: CompetitionUiTokens.titleColor(isDark),
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class _CompetitionFilterResult {
  final String? categorySlug;
  final Set<String> recommendations;
  final Set<String> recognitions;
  final Set<String> sources;

  const _CompetitionFilterResult({
    required this.categorySlug,
    required this.recommendations,
    required this.recognitions,
    required this.sources,
  });
}

class _CompetitionFilterSheet extends StatefulWidget {
  final List<CompetitionCategory> categories;
  final String? categorySlug;
  final Set<String> recommendations;
  final Set<String> recognitions;
  final Set<String> sources;
  final bool showRecommendations;

  const _CompetitionFilterSheet({
    required this.categories,
    required this.categorySlug,
    required this.recommendations,
    required this.recognitions,
    required this.sources,
    required this.showRecommendations,
  });

  @override
  State<_CompetitionFilterSheet> createState() =>
      _CompetitionFilterSheetState();
}

class _CompetitionFilterSheetState extends State<_CompetitionFilterSheet> {
  String? _categorySlug;
  late Set<String> _recommendations;
  late Set<String> _recognitions;
  late Set<String> _sources;

  @override
  void initState() {
    super.initState();
    _categorySlug = widget.categorySlug;
    _recommendations = {...widget.recommendations};
    _recognitions = {...widget.recognitions};
    _sources = {...widget.sources};
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: CompetitionUiTokens.pageBg(isDark),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: CompetitionUiTokens.borderColor(isDark),
                  borderRadius: BorderRadius.circular(
                    CompetitionUiTokens.chipRadius,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '筛选比赛',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                          color: CompetitionUiTokens.titleColor(isDark),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        _categorySlug = null;
                        _recommendations.clear();
                        _recognitions.clear();
                        _sources.clear();
                      }),
                      child: const Text('重置'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    _sheetSection('比赛领域'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _choiceChip(
                          '全部',
                          _categorySlug == null,
                          () => setState(() => _categorySlug = null),
                        ),
                        ...widget.categories.map(
                          (c) => _choiceChip(
                            c.name,
                            _categorySlug == c.slug,
                            () => setState(() => _categorySlug = c.slug),
                          ),
                        ),
                      ],
                    ),
                    if (widget.showRecommendations)
                      _sheetMulti(
                          '推荐程度',
                          {
                            'S': 'S强烈推荐',
                            'A': 'A推荐',
                            'B': 'B可参加',
                            'C': 'C兴趣',
                          },
                          _recommendations),
                    _sheetMulti(
                        '学校认定',
                        {
                          'recognized': '已认定',
                          'not_recognized': '未认定',
                          'pending': '待确认',
                          'unknown': '未知',
                        },
                        _recognitions),
                    _sheetMulti(
                        '来源类型',
                        {
                          'school_catalog': '学校目录',
                          'enterprise': '企业赛事',
                          'college_notice': '学院通知',
                          'industry_association': '行业协会',
                          'platform': '平台赛事',
                          'admin_manual': '管理员精选',
                          'ai_import': 'AI导入',
                        },
                        _sources),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      _CompetitionFilterResult(
                        categorySlug: _categorySlug,
                        recommendations: {..._recommendations},
                        recognitions: {..._recognitions},
                        sources: {..._sources},
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: CompetitionUiTokens.accent(isDark),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text('查看结果'),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sheetSection(String title) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      title,
      style: TextStyle(
        color: CompetitionUiTokens.titleColor(isDark),
        fontSize: 15,
        fontWeight: FontWeight.w900,
      ),
    );
  }

  Widget _sheetMulti(
    String title,
    Map<String, String> options,
    Set<String> set,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sheetSection(title),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: options.entries
                .map(
                  (entry) => _choiceChip(
                    entry.value,
                    set.contains(entry.key),
                    () => setState(() {
                      set.contains(entry.key)
                          ? set.remove(entry.key)
                          : set.add(entry.key);
                    }),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _choiceChip(String label, bool selected, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
      labelStyle: TextStyle(
        color: selected
            ? CompetitionUiTokens.accent(isDark)
            : CompetitionUiTokens.subColor(isDark),
        fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
      ),
      selectedColor: CompetitionUiTokens.accentSoft(isDark),
      backgroundColor: CompetitionUiTokens.cardBg(isDark),
      side: BorderSide(
        color: selected
            ? CompetitionUiTokens.accent(isDark).withValues(alpha: 0.32)
            : CompetitionUiTokens.borderColor(isDark),
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(CompetitionUiTokens.chipRadius),
      ),
    );
  }
}

class CompetitionCalendarScreen extends StatefulWidget {
  const CompetitionCalendarScreen({super.key});

  @override
  State<CompetitionCalendarScreen> createState() =>
      _CompetitionCalendarScreenState();
}

class _CompetitionCalendarScreenState extends State<CompetitionCalendarScreen> {
  List<dynamic> _items = [];
  List<CompetitionCategory> _categories = [];
  bool _loading = true;

  final _searchController = TextEditingController();
  final Set<int> _selectedEventIds = {};
  bool _selectionMode = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted) setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final dio = context.read<AuthProvider>().dio;
      final results = await Future.wait([
        dio.get('/user/competition-calendar'),
        dio.get('/competitions/categories'),
      ]);
      if (!mounted) return;
      setState(() {
        _items = (results[0].data['items'] as List?) ?? [];
        _categories = ((results[1].data as List?) ?? [])
            .map((e) => CompetitionCategory.fromJson(e))
            .toList();
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '加载我的竞赛计划失败'),
        isError: true,
      );
    }
  }

  Future<void> _share() async {
    try {
      if (!mounted) return;
      final resp = await context.read<AuthProvider>().dio.post(
            '/user/competition-calendar/share',
          );
      if (!mounted) return;
      final code = '${resp.data['share_code'] ?? ''}';
      await Clipboard.setData(ClipboardData(text: code));
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '分享码已复制：$code');
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '生成分享码失败'),
        isError: true,
      );
    }
  }

  Future<void> _openEditor({Map<String, dynamic>? item}) async {
    if (_categories.isEmpty) {
      AppFeedback.showSnackBar(context, '分类加载失败，暂时无法编辑比赛', isError: true);
      return;
    }
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CompetitionCalendarItemEditorScreen(
          categories: _categories,
          item: item,
        ),
      ),
    );
    if (changed == true) {
      await _load();
    }
  }

  Future<void> _openCalendarItemDetail(Map<String, dynamic> item) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CompetitionCalendarItemDetailScreen(
          item: item,
          categories: _categories,
        ),
      ),
    );

    if (changed == true) {
      await _load();
    }
  }

  Future<void> _deleteItem(Map<String, dynamic> item) async {
    final dio = context.read<AuthProvider>().dio;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除比赛'),
        content: Text('确定从我的计划删除「${item['title'] ?? '未命名比赛'}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await dio.delete('/user/competition-calendar/items/${item['id']}');
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已删除比赛');
      await _load();
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '删除失败'),
        isError: true,
      );
    }
  }

  Future<void> _archiveItem(Map<String, dynamic> item) async {
    final data = _calendarItemUpdatePayload(item)..['plan_status'] = 'archived';
    try {
      await context.read<AuthProvider>().dio.put(
            '/user/competition-calendar/items/${item['id']}',
            data: data,
          );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '已归档比赛');
      await _load();
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '归档失败'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);
    final titleColor = CompetitionUiTokens.titleColor(isDark);

    final items = _calendarItems;
    final grouped = _groupCalendarItems(items);
    final flattenedRows = _flattenedList(grouped);
    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: titleColor,
        centerTitle: true,
        title: Text(
          '我的竞赛计划',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '分享',
            onPressed: _share,
            icon: const Icon(Icons.share_rounded),
          ),
          IconButton(
            tooltip: '批量管理',
            onPressed: () {
              setState(() {
                _selectionMode = !_selectionMode;
                if (!_selectionMode) _selectedEventIds.clear();
              });
            },
            icon: Icon(
              _selectionMode ? Icons.close_rounded : Icons.checklist_rounded,
            ),
          ),
          IconButton(
            tooltip: '新增比赛',
            onPressed: () => _openEditor(),
            icon: const Icon(Icons.add_rounded),
          ),
          IconButton(
            tooltip: '导入计划',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const CompetitionShareImportScreen(),
              ),
            ).then((_) => _load()),
            icon: const Icon(Icons.input_rounded),
          ),
        ],
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                color: CompetitionUiTokens.accent(isDark),
              ),
            )
          : Column(
              children: [
                if (_selectionMode)
                  CompetitionBatchSelectionBar(
                    selectedCount: _selectedEventIds.length,
                    allItemsSelected:
                        _selectedEventIds.length == items.length &&
                            items.isNotEmpty,
                    allItemsLabel: '全选 (${items.length})',
                    onToggleSelectAll: () {
                      setState(() {
                        if (_selectedEventIds.length == items.length) {
                          _selectedEventIds.clear();
                        } else {
                          _selectedEventIds.addAll(
                            items.map((e) => _calendarInt(e['id'])),
                          );
                        }
                      });
                    },
                    onActionClick: _openBatchActionSheet,
                    onCancel: () {
                      setState(() {
                        _selectionMode = false;
                        _selectedEventIds.clear();
                      });
                    },
                  ),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        sliver: SliverToBoxAdapter(
                          child: _buildSearchBox(isDark),
                        ),
                      ),
                      if (items.isEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverToBoxAdapter(
                            child: CompetitionEmptyState(
                              title: '还没有加入竞赛计划',
                              message: '时间不确定也可以先关注比赛，后续看到学校通知后再补充准确时间。',
                              primaryText: '去发现比赛',
                              onPrimaryTap: () => Navigator.maybePop(context),
                              secondaryText: '手动添加',
                              onSecondaryTap: () => _openEditor(),
                            ),
                          ),
                        ),
                      if (items.isNotEmpty)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                          sliver: SliverList.builder(
                            itemCount: flattenedRows.length,
                            itemBuilder: (context, index) {
                              final row = flattenedRows[index];
                              if (row['isHeader'] == true) {
                                return _buildGroupHeader(
                                  row['title'],
                                  row['count'],
                                  isDark,
                                );
                              }
                              return _buildPlanCard(row);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  List<dynamic> _flattenedList(
    Map<String, List<Map<String, dynamic>>> grouped,
  ) {
    final groups = {
      'now': '现在该做',
      'soon': '近期关注',
      'later': '长期关注',
      'done': '已结束',
    };
    final flattened = <dynamic>[];
    for (final key in groups.keys) {
      final groupItems = grouped[key]!;
      if (groupItems.isNotEmpty) {
        flattened.add({
          'isHeader': true,
          'title': groups[key],
          'count': groupItems.length,
        });
        flattened.addAll(groupItems);
      }
    }
    return flattened;
  }

  List<Map<String, dynamic>> get _calendarItems {
    final keyword = _searchController.text.trim().toLowerCase();
    return _items
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) {
      if (keyword.isEmpty) return true;
      final title = '${item['title'] ?? ''}'.toLowerCase();
      final userNote = '${item['user_note'] ?? ''}'.toLowerCase();
      final source = competitionSourceLabel(
        '${item['source_type'] ?? ''}',
      ).toLowerCase();
      return title.contains(keyword) ||
          userNote.contains(keyword) ||
          source.contains(keyword);
    }).toList();
  }

  Widget _buildSearchBox(bool isDark) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: CompetitionUiTokens.cardBg(isDark),
        borderRadius: BorderRadius.circular(CompetitionUiTokens.cardRadius),
        border: Border.all(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            color: CompetitionUiTokens.subColor(isDark),
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索比赛名称 / 备注 / 来源',
                hintStyle: TextStyle(
                  color: CompetitionUiTokens.subColor(isDark),
                  fontSize: 14,
                ),
                border: InputBorder.none,
                isCollapsed: true,
              ),
              style: TextStyle(
                fontSize: 14,
                color: CompetitionUiTokens.titleColor(isDark),
              ),
            ),
          ),
          if (_searchController.text.isNotEmpty)
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              icon: Icon(
                Icons.close_rounded,
                size: 16,
                color: CompetitionUiTokens.subColor(isDark),
              ),
              onPressed: () => _searchController.clear(),
            ),
        ],
      ),
    );
  }

  Widget _buildGroupHeader(String title, int count, bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 6),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: CompetitionUiTokens.accent(isDark),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: CompetitionUiTokens.titleColor(isDark),
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(
              color: CompetitionUiTokens.subColor(isDark),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlanCard(Map<String, dynamic> item) {
    final deadline = _calendarItemTimeText(
      item,
      'registration_end',
      'registration_time_text',
    );
    final source = competitionSourceLabel('${item['source_type'] ?? ''}');
    final planStatus = _calendarPlanStatus(item);
    final timeStatus = _calendarTimeStatus(item);

    final id = _calendarInt(item['id']);
    return MyCompetitionPlanCard(
      item: item,
      planStatusLabel: _planStatusLabel(planStatus),
      timeStatusLabel: _timeStatusLabel(timeStatus),
      sourceLabel: source,
      deadlineText: deadline,
      selectionMode: _selectionMode,
      isSelected: _selectedEventIds.contains(id),
      onSelect: () {
        setState(() {
          if (_selectedEventIds.contains(id)) {
            _selectedEventIds.remove(id);
          } else {
            _selectedEventIds.add(id);
          }
        });
      },
      onTap: () {
        if (_selectionMode) {
          setState(() {
            if (_selectedEventIds.contains(id)) {
              _selectedEventIds.remove(id);
            } else {
              _selectedEventIds.add(id);
            }
          });
        } else {
          _openCalendarItemDetail(item);
        }
      },
      onEdit: () => _openEditor(item: item),
      onDelete: () => _deleteItem(item),
      onArchive: () => _archiveItem(item),
    );
  }

  void _openBatchActionSheet() {
    if (_selectedEventIds.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => CompetitionBatchActionSheet(
        selectedCount: _selectedEventIds.length,
        actions: const [
          CompetitionBatchAction(
            value: 'watching',
            label: '恢复关注',
            icon: Icons.visibility_outlined,
          ),
          CompetitionBatchAction(
            value: 'preparing',
            label: '设为准备中',
            icon: Icons.model_training_rounded,
          ),
          CompetitionBatchAction(
            value: 'registered',
            label: '设为已报名',
            icon: Icons.how_to_reg_rounded,
          ),
          CompetitionBatchAction(
            value: 'submitted',
            label: '设为已提交',
            icon: Icons.upload_file_rounded,
          ),
          CompetitionBatchAction(
            value: 'finished',
            label: '标记已结束',
            icon: Icons.emoji_events_outlined,
          ),
          CompetitionBatchAction(
            value: 'archived',
            label: '归档',
            icon: Icons.inventory_2_outlined,
          ),
          CompetitionBatchAction(
            value: 'delete',
            label: '删除',
            icon: Icons.delete_outline_rounded,
            danger: true,
          ),
        ],
        onActionSelected: (value) {
          final labels = {
            'watching': '恢复关注',
            'preparing': '设为准备中',
            'registered': '设为已报名',
            'submitted': '设为已提交',
            'finished': '标记已结束',
            'archived': '归档',
            'delete': '删除',
          };
          _batchAction(value, labels[value]!);
        },
      ),
    );
  }

  Future<void> _batchAction(String action, String actionLabel) async {
    final ids = _selectedEventIds.toList();
    if (ids.isEmpty) return;

    final isDelete = action == 'delete';
    final dio = context.read<AuthProvider>().dio;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => CompetitionBatchConfirmDialog(
        title: '确认批量$actionLabel',
        content: '即将对选中的 ${ids.length} 项比赛执行$actionLabel。'
            '${isDelete ? '\n\n注意：这些项目只会从“我的竞赛计划”移除，不会删除官方竞赛库中的比赛。' : ''}',
        confirmLabel: '确认',
        isDanger: isDelete,
      ),
    );
    if (confirmed != true) return;

    try {
      final response = await dio.post(
        '/user/competition-calendar/items/batch-action',
        data: buildCompetitionCalendarBatchActionPayload(
          ids: ids,
          action: action,
        ),
      );
      if (!mounted) return;
      final data = response.data as Map<String, dynamic>?;
      final success = (data?['success_count'] as num?)?.toInt() ?? 0;
      final skipped = (data?['skipped_count'] as num?)?.toInt() ?? 0;
      AppFeedback.showSnackBar(
        context,
        '批量$actionLabel完成：成功 $success，跳过 $skipped',
      );
      setState(() {
        _selectionMode = false;
        _selectedEventIds.clear();
      });
      await _load();
    } catch (_) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '批量$actionLabel部分或全部失败', isError: true);
      await _load();
    }
  }

  Map<String, List<Map<String, dynamic>>> _groupCalendarItems(
    List<Map<String, dynamic>> items,
  ) {
    final groups = {
      'now': <Map<String, dynamic>>[],
      'soon': <Map<String, dynamic>>[],
      'later': <Map<String, dynamic>>[],
      'done': <Map<String, dynamic>>[],
    };
    for (final item in items) {
      final key = _calendarItemGroup(item);
      groups[key]!.add(item);
    }
    return groups;
  }

  String _calendarItemGroup(Map<String, dynamic> item) {
    final now = DateTime.now();
    final planStatus = _calendarPlanStatus(item);
    final deadline = _parseCalendarDate(item['registration_end']);
    if (planStatus == 'finished' ||
        planStatus == 'archived' ||
        (deadline != null && deadline.isBefore(now))) {
      return 'done';
    }
    final userDeadline = _parseCalendarDate(item['user_deadline']);
    if (_isWithinDays(deadline, now, 30) ||
        _isWithinDays(userDeadline, now, 30) ||
        const {'preparing', 'registered', 'submitted'}.contains(planStatus)) {
      return 'now';
    }
    final sortDate = _parseCalendarDate(item['sort_date']);
    final sortMonth = _calendarInt(item['sort_month']);
    if (_isWithinDays(sortDate, now, 90) || _isNearMonth(sortMonth, now)) {
      return 'soon';
    }
    return 'later';
  }

  Map<String, dynamic> _calendarItemUpdatePayload(Map<String, dynamic> item) {
    return {
      'title': '${item['title'] ?? ''}',
      'summary': '${item['summary'] ?? ''}',
      'description': '${item['description'] ?? ''}',
      'primary_category_id': _calendarInt(item['category_id']),
      'competition_level':
          '${item['competition_level'] ?? item['level'] ?? ''}',
      'school_recognition_status':
          '${item['school_recognition_status'] ?? 'pending'}',
      'recommendation_level': '${item['recommendation_level'] ?? 'A'}',
      'organizer': '${item['organizer'] ?? ''}',
      'registration_end': _calendarDateOnly(item['registration_end']),
      'registration_time_text': '${item['registration_time_text'] ?? ''}',
      'event_start': _calendarDateOnly(item['event_start']),
      'event_time_text': '${item['event_time_text'] ?? ''}',
      'time_precision': '${item['time_precision'] ?? 'unknown'}',
      'time_status': _calendarTimeStatus(item),
      'time_note': '${item['time_note'] ?? ''}',
      'sort_month': _calendarInt(item['sort_month']),
      'user_deadline': _calendarDateOnly(item['user_deadline']),
      'location': '${item['location'] ?? ''}',
      'is_online': item['is_online'] == true,
      'official_url': '${item['official_url'] ?? ''}',
      'notice_url': '${item['notice_url'] ?? ''}',
      'source_channel': 'user_submitted',
      'status': 'draft',
      'tags': <String>[],
      'attachment_urls': <String>[],
    };
  }

  String _calendarPlanStatus(Map<String, dynamic> item) {
    final value = '${item['plan_status'] ?? ''}'.trim();
    return value.isEmpty ? 'watching' : value;
  }

  String _calendarTimeStatus(Map<String, dynamic> item) {
    final value = '${item['time_status'] ?? ''}'.trim();
    if (value.isNotEmpty) return value;
    if (_parseCalendarDate(item['registration_end']) != null) {
      return 'confirmed';
    }
    final text =
        '${item['registration_time_text'] ?? ''} ${item['event_time_text'] ?? ''}';
    if (_containsAny(text, const ['预计', '暂定', '计划', '大概', '约'])) {
      return 'estimated';
    }
    if (_containsAny(text, const ['往年', '历年', '通常', '一般', '参考'])) {
      return 'historical';
    }
    return 'pending';
  }

  int _calendarInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  DateTime? _parseCalendarDate(dynamic value) {
    final raw = '${value ?? ''}'.trim();
    if (raw.isEmpty || raw == 'null') return null;
    return DateTime.tryParse(raw);
  }

  String _calendarDateOnly(dynamic value) {
    final parsed = _parseCalendarDate(value);
    if (parsed == null) return '';
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }

  bool _isWithinDays(DateTime? date, DateTime now, int days) {
    if (date == null || date.isBefore(now)) return false;
    return date.difference(now).inDays <= days;
  }

  bool _isNearMonth(int month, DateTime now) {
    if (month < 1 || month > 12) return false;
    for (var offset = 0; offset < 3; offset++) {
      final candidate = DateTime(now.year, now.month + offset, 1);
      if (candidate.month == month) return true;
    }
    return false;
  }

  String _planStatusLabel(String value) {
    switch (value) {
      case 'preparing':
        return '准备中';
      case 'registered':
        return '已报名';
      case 'submitted':
        return '已提交';
      case 'finished':
        return '已结束';
      case 'archived':
        return '已归档';
      default:
        return '关注中';
    }
  }
}

class CompetitionCalendarItemEditorScreen extends StatefulWidget {
  final List<CompetitionCategory> categories;
  final Map<String, dynamic>? item;

  const CompetitionCalendarItemEditorScreen({
    super.key,
    required this.categories,
    this.item,
  });

  @override
  State<CompetitionCalendarItemEditorScreen> createState() =>
      _CompetitionCalendarItemEditorScreenState();
}

class _CompetitionCalendarItemEditorScreenState
    extends State<CompetitionCalendarItemEditorScreen> {
  final _titleController = TextEditingController();
  final _summaryController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _organizerController = TextEditingController();
  final _competitionLevelController = TextEditingController();
  final _registrationEndController = TextEditingController();
  final _registrationTextController = TextEditingController();
  final _eventStartController = TextEditingController();
  final _eventTextController = TextEditingController();
  final _locationController = TextEditingController();
  final _officialUrlController = TextEditingController();
  final _noticeUrlController = TextEditingController();

  int? _categoryId;
  String _recognition = 'pending';
  String _recommendation = 'A';
  bool _isOnline = false;
  bool _saving = false;

  bool get _isEditing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _categoryId = _intValue(item?['category_id']);
    if (_categoryId == null || _categoryId == 0) {
      _categoryId = widget.categories.first.id;
    }
    _titleController.text = '${item?['title'] ?? ''}';
    _summaryController.text = '${item?['summary'] ?? ''}';
    _descriptionController.text = '${item?['description'] ?? ''}';
    _organizerController.text = '${item?['organizer'] ?? ''}';
    _competitionLevelController.text = '${item?['competition_level'] ?? ''}';
    _registrationEndController.text = _dateOnly(item?['registration_end']);
    _registrationTextController.text =
        '${item?['registration_time_text'] ?? ''}';
    _eventStartController.text = _dateOnly(item?['event_start']);
    _eventTextController.text = '${item?['event_time_text'] ?? ''}';
    _locationController.text = '${item?['location'] ?? ''}';
    _officialUrlController.text = '${item?['official_url'] ?? ''}';
    _noticeUrlController.text = '${item?['notice_url'] ?? ''}';
    _recognition = '${item?['school_recognition_status'] ?? 'pending'}';
    if (_recognition.isEmpty) _recognition = 'pending';
    _recommendation = '${item?['recommendation_level'] ?? 'A'}';
    if (_recommendation.isEmpty) _recommendation = 'A';
    _isOnline = item?['is_online'] == true;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _summaryController.dispose();
    _descriptionController.dispose();
    _organizerController.dispose();
    _competitionLevelController.dispose();
    _registrationEndController.dispose();
    _registrationTextController.dispose();
    _eventStartController.dispose();
    _eventTextController.dispose();
    _locationController.dispose();
    _officialUrlController.dispose();
    _noticeUrlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      AppFeedback.showSnackBar(context, '请填写比赛名称', isError: true);
      return;
    }
    if (_categoryId == null || _categoryId == 0) {
      AppFeedback.showSnackBar(context, '请选择比赛分类', isError: true);
      return;
    }
    setState(() => _saving = true);
    final data = {
      'title': title,
      'summary': _summaryController.text.trim(),
      'description': _descriptionController.text.trim(),
      'primary_category_id': _categoryId,
      'competition_level': _competitionLevelController.text.trim(),
      'school_recognition_status': _recognition,
      'recommendation_level': _recommendation,
      'organizer': _organizerController.text.trim(),
      'registration_end': _registrationEndController.text.trim(),
      'registration_time_text': _registrationTextController.text.trim(),
      'event_start': _eventStartController.text.trim(),
      'event_time_text': _eventTextController.text.trim(),
      'location': _locationController.text.trim(),
      'is_online': _isOnline,
      'official_url': _officialUrlController.text.trim(),
      'notice_url': _noticeUrlController.text.trim(),
      'source_channel': 'user_submitted',
      'status': 'draft',
      'tags': <String>[],
      'attachment_urls': <String>[],
    };

    try {
      final dio = context.read<AuthProvider>().dio;
      if (_isEditing) {
        await dio.put(
          '/user/competition-calendar/items/${widget.item!['id']}',
          data: data,
        );
      } else {
        await dio.post('/user/competition-calendar/items', data: data);
      }
      if (!mounted) return;
      AppFeedback.showSnackBar(context, _isEditing ? '已更新比赛' : '已新增比赛');
      Navigator.pop(context, true);
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: _isEditing ? '更新失败' : '新增失败'),
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pageBg = CompetitionUiTokens.pageBg(isDark);
    final titleColor = CompetitionUiTokens.titleColor(isDark);

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        backgroundColor: pageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        foregroundColor: titleColor,
        centerTitle: true,
        title: Text(
          _isEditing ? '编辑比赛' : '新增比赛',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _buildFormGroup(
              '基础信息',
              [
                _input(_titleController, '比赛名称',
                    required: true, isDark: isDark),
                const SizedBox(height: 12),
                _input(_summaryController, '一句话摘要', isDark: isDark),
                const SizedBox(height: 12),
                _input(
                  _descriptionController,
                  '比赛说明',
                  minLines: 4,
                  maxLines: 8,
                  isDark: isDark,
                ),
              ],
              isDark),
          _buildFormGroup(
              '分类与推荐',
              [
                DropdownButtonFormField<int>(
                  initialValue: _categoryId,
                  decoration: _inputDecoration('比赛分类', isDark),
                  items: widget.categories
                      .map(
                        (c) =>
                            DropdownMenuItem(value: c.id, child: Text(c.name)),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => _categoryId = value),
                ),
                const SizedBox(height: 12),
                _input(_competitionLevelController, '比赛级别', isDark: isDark),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _recommendation,
                        decoration: _inputDecoration('推荐程度', isDark),
                        items: const [
                          DropdownMenuItem(value: 'S', child: Text('S 强烈推荐')),
                          DropdownMenuItem(value: 'A', child: Text('A 推荐')),
                          DropdownMenuItem(value: 'B', child: Text('B 可参加')),
                          DropdownMenuItem(value: 'C', child: Text('C 兴趣')),
                        ],
                        onChanged: (value) =>
                            setState(() => _recommendation = value ?? 'A'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _recognition,
                        decoration: _inputDecoration('学校认定', isDark),
                        items: const [
                          DropdownMenuItem(
                              value: 'recognized', child: Text('已认定')),
                          DropdownMenuItem(
                            value: 'not_recognized',
                            child: Text('未认定'),
                          ),
                          DropdownMenuItem(
                              value: 'pending', child: Text('待确认')),
                          DropdownMenuItem(value: 'unknown', child: Text('未知')),
                        ],
                        onChanged: (value) =>
                            setState(() => _recognition = value ?? 'pending'),
                      ),
                    ),
                  ],
                ),
              ],
              isDark),
          _buildFormGroup(
              '时间安排',
              [
                _input(
                  _registrationEndController,
                  '报名截止日期 YYYY-MM-DD',
                  isDark: isDark,
                ),
                const SizedBox(height: 12),
                _input(_registrationTextController, '报名时间说明', isDark: isDark),
                const SizedBox(height: 12),
                _input(_eventStartController, '比赛开始日期 YYYY-MM-DD',
                    isDark: isDark),
                const SizedBox(height: 12),
                _input(_eventTextController, '比赛时间说明', isDark: isDark),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _isOnline,
                  onChanged: (value) => setState(() => _isOnline = value),
                  title: const Text('线上比赛'),
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: Colors.white,
                  activeTrackColor: CompetitionUiTokens.accent(isDark),
                ),
              ],
              isDark),
          _buildFormGroup(
              '地点与链接',
              [
                _input(_locationController, '地点', isDark: isDark),
                const SizedBox(height: 12),
                _input(_officialUrlController, '官网链接', isDark: isDark),
                const SizedBox(height: 12),
                _input(_noticeUrlController, '通知链接', isDark: isDark),
              ],
              isDark),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: CompetitionUiTokens.accent(isDark),
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: Text(_saving ? '保存中...' : '保存比赛'),
          ),
        ),
      ),
    );
  }

  Widget _buildFormGroup(String title, List<Widget> children, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: CompetitionUiTokens.cardDecoration(isDark),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: CompetitionUiTokens.titleColor(isDark),
            ),
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _input(
    TextEditingController controller,
    String label, {
    bool required = false,
    int minLines = 1,
    int maxLines = 1,
    required bool isDark,
  }) {
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      decoration: _inputDecoration(required ? '$label *' : label, isDark),
    );
  }

  InputDecoration _inputDecoration(String label, bool isDark) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: CompetitionUiTokens.cardBg(isDark),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: CompetitionUiTokens.borderColor(isDark)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: CompetitionUiTokens.accent(isDark),
          width: 1.3,
        ),
      ),
    );
  }

  int? _intValue(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse('$value');
  }

  String _dateOnly(dynamic value) {
    final raw = '${value ?? ''}'.trim();
    if (raw.isEmpty || raw == 'null') return '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }
}

enum _ImportMode { shareCode, jsonFile }

class CompetitionShareImportScreen extends StatefulWidget {
  const CompetitionShareImportScreen({super.key});

  @override
  State<CompetitionShareImportScreen> createState() =>
      _CompetitionShareImportScreenState();
}

class _CompetitionShareImportScreenState
    extends State<CompetitionShareImportScreen> {
  _ImportMode _mode = _ImportMode.shareCode;

  final _controller = TextEditingController();
  Map<String, dynamic>? _preview;
  bool _readingJsonFile = false;
  String? _jsonFileName;
  Map<String, dynamic>? _jsonPayload;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _previewShare() async {
    if (!mounted) return;
    final resp = await context.read<AuthProvider>().dio.post(
      '/user/competition-calendar/import-share/preview',
      data: {'share_code': _controller.text.trim()},
    );
    if (!mounted) return;
    setState(() => _preview = Map<String, dynamic>.from(resp.data));
  }

  Future<void> _commitShare(String strategy) async {
    await context.read<AuthProvider>().dio.post(
      '/user/competition-calendar/import-share/commit',
      data: {'share_code': _controller.text.trim(), 'strategy': strategy},
    );
    if (!mounted) return;
    AppFeedback.showSnackBar(context, '导入完成');
    Navigator.pop(context);
  }

  Future<void> _pickJsonFile() async {
    try {
      setState(() => _readingJsonFile = true);

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
        withReadStream: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.single;

      String? text;
      if (file.bytes != null) {
        text = utf8.decode(file.bytes!).trim();
      } else if (file.readStream != null) {
        text = await file.readStream!.transform(utf8.decoder).join();
        text = text.trim();
      }

      if (text == null || text.isEmpty) {
        if (!mounted) return;
        AppFeedback.showSnackBar(
          context,
          '读取文件失败，请重新选择 JSON 文件',
          isError: true,
        );
        return;
      }

      final decoded = jsonDecode(text);

      if (decoded is! Map<String, dynamic> || decoded['events'] is! List) {
        if (!mounted) return;
        AppFeedback.showSnackBar(
          context,
          'JSON 顶层必须是 {"events": [...]}',
          isError: true,
        );
        return;
      }

      if (!mounted) return;
      final resp = await context.read<AuthProvider>().dio.post(
            '/user/competition-calendar/import-json/preview',
            data: decoded,
          );

      if (!mounted) return;

      setState(() {
        _jsonFileName = file.name;
        _jsonPayload = decoded;
        _preview = Map<String, dynamic>.from(resp.data['preview']);
      });

      AppFeedback.showSnackBar(context, '已读取 ${file.name}');
    } on FormatException {
      AppFeedback.showSnackBar(
        context,
        'JSON 格式不正确，请检查逗号、引号和括号',
        isError: true,
      );
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '读取 JSON 文件或预览失败'),
        isError: true,
      );
    } catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '读取 JSON 文件或预览失败：$e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _readingJsonFile = false);
      }
    }
  }

  Future<void> _commitJson(String strategy) async {
    if (_jsonPayload == null) return;
    try {
      await context.read<AuthProvider>().dio.post(
        '/user/competition-calendar/import-json/commit',
        data: {'strategy': strategy, 'events': _jsonPayload!['events']},
      );
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '导入完成');
      Navigator.pop(context);
    } on DioException catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(
        context,
        AppFeedback.dioErrorMessage(e, fallback: '导入失败'),
        isError: true,
      );
    } catch (e) {
      if (!mounted) return;
      AppFeedback.showSnackBar(context, '导入失败：$e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = (_preview?['items'] as List?) ?? [];
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('导入计划')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<_ImportMode>(
            segments: const [
              ButtonSegment(value: _ImportMode.shareCode, label: Text('分享码导入')),
              ButtonSegment(
                value: _ImportMode.jsonFile,
                label: Text('JSON 文件导入'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (Set<_ImportMode> newSelection) {
              setState(() {
                _mode = newSelection.first;
                _preview = null;
              });
            },
          ),
          const SizedBox(height: 24),
          if (_mode == _ImportMode.shareCode) ...[
            TextField(
              controller: _controller,
              decoration: const InputDecoration(labelText: '分享码'),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _previewShare, child: const Text('预览')),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: CompetitionUiTokens.cardBg(isDark),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: CompetitionUiTokens.borderColor(isDark),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _jsonFileName == null ? '未选择文件' : '已选择: $_jsonFileName',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: CompetitionUiTokens.titleColor(isDark),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _readingJsonFile ? null : _pickJsonFile,
                    icon: const Icon(Icons.upload_file_rounded, size: 18),
                    label: Text(_readingJsonFile ? '读取中...' : '选择 JSON 文件'),
                  ),
                ],
              ),
            ),
          ],
          if (_preview != null) ...[
            const SizedBox(height: 16),
            Text(
              '预览 ${items.length} 个比赛',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            ...items.map((e) => ListTile(title: Text(e['title'] ?? ''))),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _mode == _ImportMode.shareCode
                        ? _commitShare('merge')
                        : _commitJson('merge'),
                    child: const Text('合并'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _mode == _ImportMode.shareCode
                        ? _commitShare('replace')
                        : _commitJson('replace'),
                    child: const Text('覆盖'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CompetitionTimeLine {
  final String label;
  final String value;

  const _CompetitionTimeLine({required this.label, required this.value});
}

/// 时间状态只用于展示文案，配色统一走 [CompetitionUiTokens]。
String _competitionTimeStateLabel(CompetitionEvent event) {
  final deadline = event.registrationEnd;
  if (deadline != null) {
    return deadline.isBefore(DateTime.now()) ? '已截止' : '已确认';
  }

  if (event.hasTimeStatus) {
    switch (event.timeStatus) {
      case 'confirmed':
        return '已确认';
      case 'estimated':
        return '预计时间';
      case 'historical':
        return '往年参考';
      default:
        return '时间待公布';
    }
  }

  final text = '${event.registrationTimeText} ${event.eventTimeText}';
  if (_containsAny(text, const ['预计', '暂定', '计划', '大概', '约'])) {
    return '预计时间';
  }
  if (_containsAny(text, const ['往年', '历年', '通常', '一般', '参考'])) {
    return '往年参考';
  }
  return '时间待公布';
}

_CompetitionTimeLine? _competitionTimeLine(CompetitionEvent event) {
  if (event.registrationEnd != null) {
    return _CompetitionTimeLine(label: '报名截止', value: _deadlineText(event));
  }
  if (event.registrationTimeText.trim().isNotEmpty) {
    return _CompetitionTimeLine(
      label: '报名窗口',
      value: event.registrationTimeText.trim(),
    );
  }
  if (event.eventTimeText.trim().isNotEmpty) {
    return _CompetitionTimeLine(
      label: '比赛时间',
      value: event.eventTimeText.trim(),
    );
  }
  if (event.sortMonth >= 1 && event.sortMonth <= 12) {
    return _CompetitionTimeLine(label: '预计月份', value: '${event.sortMonth} 月左右');
  }
  return null;
}

bool _containsAny(String value, List<String> keywords) {
  return keywords.any(value.contains);
}

String _deadlineText(CompetitionEvent event) {
  final dt = event.registrationEnd;
  if (dt != null) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
  return event.registrationTimeText;
}

String _calendarItemTimeText(
  Map<String, dynamic> item,
  String dateKey,
  String textKey,
) {
  final rawDate = '${item[dateKey] ?? ''}'.trim();
  final parsed = DateTime.tryParse(rawDate);
  if (parsed != null) {
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }
  return '${item[textKey] ?? ''}'.trim();
}

String _timeStatusLabel(String value) {
  switch (value) {
    case 'confirmed':
      return '已确认';
    case 'estimated':
      return '预计时间';
    case 'historical':
      return '往年参考';
    case 'pending':
      return '时间待公布';
    default:
      return value.isEmpty ? '时间待公布' : value;
  }
}

String _sourceLabel(String value) {
  switch (value) {
    case 'school_catalog':
      return '学校目录';
    case 'ministry_list':
      return '官方榜单';
    case 'college_notice':
      return '学院通知';
    case 'enterprise':
      return '企业赛事';
    case 'industry_association':
      return '行业协会';
    case 'platform':
      return '平台赛事';
    case 'user_submitted':
      return '用户补充';
    case 'admin_manual':
      return '管理员精选';
    case 'ai_import':
      return 'AI导入';
    default:
      return value.isEmpty ? '未知来源' : value;
  }
}
