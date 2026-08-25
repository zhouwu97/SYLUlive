import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_bootstrap.dart';
import '../models/campus_article.dart';
import '../models/ai_capabilities.dart';
import '../models/exam_schedule.dart';
import '../services/ai_assistant_service.dart';
import '../services/app_resume_coordinator.dart';
import '../services/campus_article_service.dart';
import '../services/exam_schedule_repository.dart';
import '../providers/course_schedule_provider.dart';
import '../widgets/home_tab_reveal.dart';
import '../utils/campus_asset_preloader.dart';
import '../utils/app_feedback.dart';
import '../utils/campus_today.dart';
import '../utils/app_navigation.dart';
import '../utils/app_navigator.dart';

import '../widgets/campus/campus_theme.dart';
import '../widgets/campus/campus_ai_entry_card.dart';
import '../widgets/campus/campus_header.dart';
import '../widgets/campus/campus_feature_notice_card.dart';
import '../widgets/campus/campus_service_grid.dart';
import '../widgets/campus/campus_news_section_header.dart';
import '../widgets/campus/campus_news_card.dart';
import '../widgets/campus/campus_today_card.dart';

import 'campus_article_detail_screen.dart';
import 'ai/ai_assistant_screen.dart';
import 'campus_article_list_screen.dart';
import 'campus_calendar_screen.dart';
import 'campus_map_tab_page.dart';
import 'competition_center_screen.dart';
import 'edu_screen.dart';
import 'exam_schedule_screen.dart';
import 'canteen_screen.dart';
import 'campus_ranking_screen.dart';
import 'team/team_recruitment_center_screen.dart';

class CampusScreen extends StatefulWidget {
  /// 可选依赖仅用于测试；生产环境继续复用全局 Dio 与鉴权头。
  final CampusArticleService? articleService;
  final AiAssistantService? aiService;

  /// 可选时钟注入仅用于测试；生产环境使用真实时间。
  final DateTime Function()? nowProvider;

  const CampusScreen({
    super.key,
    this.articleService,
    this.aiService,
    this.nowProvider,
  });

  @override
  State<CampusScreen> createState() => _CampusScreenState();
}

class _CampusScreenState extends State<CampusScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  late CampusArticleService _articleService;
  late AiAssistantService _aiService;
  AiCapabilities? _aiCapabilities;

  // 最新文章
  CampusArticleSummary? _latestArticle;
  String? _latestError;
  bool _latestLoaded = false;

  // 今日卡片（UX-5）
  List<CampusTodayItem> _todayItems = [];
  List<CourseBlock> _cachedTodayCourses = const [];
  List<ExamModel> _cachedTodayExams = const [];
  Timer? _todayTimer;

  // 最近文章列表
  List<CampusArticleSummary> _recentArticles = [];
  String? _recentError;
  bool _recentLoaded = false;
  bool _assetsPreloaded = false;

  Future<void>? _loadFuture;
  int _loadGeneration = 0;
  VoidCallback? _unregisterResumeRefresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final dio = getSharedDio();
    _articleService = widget.articleService ?? CampusArticleService(dio);
    _aiService = widget.aiService ?? AiAssistantService(dio);
    _unregisterResumeRefresh =
        AppResumeCoordinator.instance.registerVisibleRefresh(
      () => _loadAll(force: true),
      isVisible: () => currentHomeTabIndex.value == 3,
    );
    _loadAll();
    _startTodayTimer();
  }

  @override
  void dispose() {
    _unregisterResumeRefresh?.call();
    WidgetsBinding.instance.removeObserver(this);
    _todayTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startTodayTimer();
      _recomputeTodayItems();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _todayTimer?.cancel();
      _todayTimer = null;
    }
  }

  void _startTodayTimer() {
    if (_todayTimer != null) return;
    _todayTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _recomputeTodayItems(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_assetsPreloaded) return;
    _assetsPreloaded = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) CampusAssetPreloader.warmMap(context);
    });
  }

  Future<void> _loadAll({bool force = false}) async {
    if (force) {
      _loadFuture = null;
      _cachedTodayCourses = const [];
      _cachedTodayExams = const [];
    }
    if (_loadFuture != null) return _loadFuture!;
    final generation = ++_loadGeneration;
    _loadFuture = Future.wait([
      _loadLatest(generation),
      _loadRecent(generation),
      _loadAiCapabilities(generation),
      _loadTodayItems(generation),
    ]).whenComplete(() {
      if (_loadGeneration == generation) {
        _loadFuture = null;
      }
    });
    return _loadFuture!;
  }

  Future<void> _loadAiCapabilities(int generation) async {
    try {
      final capabilities = await _aiService.getCapabilities();
      if (mounted && _loadGeneration == generation) {
        setState(() {
          _aiCapabilities = capabilities.isVisible ? capabilities : null;
        });
      }
    } catch (_) {
      // AI 能力不可用时不影响校园资讯主体展示。
      if (mounted && _loadGeneration == generation && _aiCapabilities != null) {
        setState(() => _aiCapabilities = null);
      }
    }
  }

  Future<void> _loadLatest(int generation) async {
    try {
      final article = await _articleService.getLatestArticle();
      if (mounted && _loadGeneration == generation) {
        setState(() {
          _latestArticle = article;
          _latestError = null;
          _latestLoaded = true;
        });
      }
    } on CampusArticleServiceException catch (e) {
      _handleLoadError(e.message, generation, isLatest: true);
    } catch (e) {
      _handleLoadError('加载失败', generation, isLatest: true);
    }
  }

  Future<void> _loadRecent(int generation) async {
    try {
      // 并行请求：通用最新列表 + 比赛通知最新，保证比赛通知有曝光位
      final results = await Future.wait([
        _articleService.getArticles(page: 1, pageSize: 6),
        _articleService.getArticles(
          page: 1,
          pageSize: 1,
          categorySlug: 'competition',
        ),
      ]);

      final normalPage = results[0];
      final competitionPage = results[1];

      // 合并去重：如果比赛通知不在通用列表中，强制插入
      final normalIds = normalPage.items.map((a) => a.id).toSet();
      final missingCompetitions = competitionPage.items
          .where((a) => !normalIds.contains(a.id))
          .toList();

      final merged = <CampusArticleSummary>[
        ...normalPage.items,
        ...missingCompetitions,
      ];

      // 按发布日期排序
      merged.sort((a, b) => b.publishDate.compareTo(a.publishDate));

      if (mounted && _loadGeneration == generation) {
        setState(() {
          _recentArticles = merged;
          _recentError = null;
          _recentLoaded = true;
        });
      }
    } on CampusArticleServiceException catch (e) {
      _handleLoadError(e.message, generation, isLatest: false);
    } catch (e) {
      _handleLoadError('加载失败', generation, isLatest: false);
    }
  }

  void _handleLoadError(String message, int generation,
      {required bool isLatest}) {
    if (!mounted || _loadGeneration != generation) return;

    final hasOldData =
        isLatest ? _latestArticle != null : _recentArticles.isNotEmpty;
    if (hasOldData) {
      AppFeedback.error(
        '${isLatest ? '头条' : '资讯'}刷新失败: $message',
        context: context,
      );
    } else {
      setState(() {
        if (isLatest) {
          _latestError = message;
          _latestLoaded = true;
        } else {
          _recentError = message;
          _recentLoaded = true;
        }
      });
    }
  }

  // ── 今日卡片（UX-5）───────────────────────────────────────────────
  // 数据只来自已有 Provider / 本地缓存 / 已加载 Snapshot，禁止在 build 中
  // 发起网络请求；计时器只重算已缓存数据，不会在后台触发网络请求。
  DateTime _currentTime() => widget.nowProvider?.call() ?? DateTime.now();

  Future<void> _loadTodayItems(int generation) async {
    CourseScheduleProvider? schedule;
    try {
      schedule = context.read<CourseScheduleProvider>();
    } catch (_) {
      // 宿主未挂载课表 Provider 时，课程项独立降级隐藏。
    }

    if (schedule != null) {
      try {
        if (schedule.semesterStart == null) {
          await schedule.loadSemesterStart();
        }
        if (schedule.courses.isEmpty) {
          await schedule.loadCachedCoursesIfAvailable();
        }
        final week = schedule.getAcademicWeek(_currentTime());
        _cachedTodayCourses = week == null
            ? const []
            : schedule.courses
                .where((course) => schedule!.isCourseActive(course, week))
                .toList(growable: false);
      } catch (_) {
        _cachedTodayCourses = const [];
      }
    } else {
      _cachedTodayCourses = const [];
    }

    try {
      _cachedTodayExams =
          (await ExamScheduleRepository().load()).toList(growable: false);
    } catch (_) {
      _cachedTodayExams = const [];
    }

    if (mounted && _loadGeneration == generation) {
      _recomputeTodayItems(generation: generation);
    }
  }

  void _recomputeTodayItems({int? generation}) {
    if (!mounted || (generation != null && generation != _loadGeneration)) {
      return;
    }
    final entries = buildCampusTodayEntries(
      now: _currentTime(),
      courses: _cachedTodayCourses,
      exams: _cachedTodayExams,
    );
    final items = entries
        .map(
          (entry) => CampusTodayItem(
            id: entry.id,
            icon: entry.kind == CampusTodayEntryKind.course
                ? Icons.menu_book_rounded
                : Icons.edit_calendar_rounded,
            title: entry.title,
            subtitle: entry.subtitle,
            onTap: () {
              if (entry.kind == CampusTodayEntryKind.course) {
                unawaited(AppNavigation.openTimetable(context));
                return;
              }
              unawaited(_openPage(const ExamScheduleScreen()));
            },
          ),
        )
        .toList(growable: false);
    setState(() => _todayItems = items);
  }

  String _currentSemesterText() {
    final now = DateTime.now();
    if (now.month >= 9) {
      return '${now.year}—${now.year + 1}学年 · 第一学期';
    }
    return '${now.year - 1}—${now.year}学年 · 第二学期';
  }

  Future<void> _openPage(Widget page) async {
    HapticFeedback.selectionClick();
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _openAiAssistant({String? initialPrompt}) async {
    final capabilities = _aiCapabilities;
    if (capabilities == null) return;
    await _openPage(
      AiAssistantScreen(
        capabilities: capabilities,
        service: _aiService,
        dio: getSharedDio(),
        initialPrompt: initialPrompt,
      ),
    );
  }

  void _openArticleDetail(CampusArticleSummary article) {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CampusArticleDetailScreen(summary: article),
      ),
    );
  }

  /// 用于显示的"最新文章"——优先取 _latestArticle；
  /// 如果最新加载失败但列表成功，用列表第一条。
  CampusArticleSummary? get _displayLatest {
    if (_latestArticle != null) return _latestArticle;
    if (_latestError != null && _recentArticles.isNotEmpty) {
      return _recentArticles.first;
    }
    return null;
  }

  /// 用于显示的最近列表——排除最新文章的 id，避免重复。
  List<CampusArticleSummary> get _displayRecent {
    final latest = _displayLatest;
    if (latest == null) return _recentArticles;
    return _recentArticles.where((a) => a.id != latest.id).take(5).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // 今日卡片有数据才显示；其存在时下方模块的入场动画索引整体后移一格。
    final todayShown = _todayItems.isNotEmpty;

    return Scaffold(
      backgroundColor: isDark ? CampusTheme.darkBg : CampusTheme.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () => _loadAll(force: true),
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    HomeTabRevealItem(
                      index: 0,
                      child: CampusHeader(semester: _currentSemesterText()),
                    ),
                    if (todayShown) ...[
                      const SizedBox(height: 10),
                      HomeTabRevealItem(
                        index: 1,
                        child: CampusTodayCard(
                          items: _todayItems,
                          isDark: isDark,
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    HomeTabRevealItem(
                      index: todayShown ? 2 : 1,
                      child: _buildLatestCard(isDark),
                    ),
                    if (_aiCapabilities != null) ...[
                      const SizedBox(height: 12),
                      HomeTabRevealItem(
                        index: todayShown ? 3 : 2,
                        child: CampusAiEntryCard(
                          capabilities: _aiCapabilities!,
                          isDark: isDark,
                          onTap: _openAiAssistant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    // 仅保留校园服务区域的 Root Tab Reveal；服务项自身不再
                    // 叠加 stagger、透明度和位移动画。
                    HomeTabRevealItem(
                      index: _aiCapabilities == null
                          ? (todayShown ? 3 : 2)
                          : (todayShown ? 4 : 3),
                      child: CampusServiceGrid(
                        isDark: isDark,
                        onEduTap: () => _openPage(const EduScreen()),
                        onCanteenTap: () => _openPage(const CanteenScreen()),
                        onRateTap: () => _openPage(const CampusRankingScreen()),
                        onTeamTap: () =>
                            _openPage(const TeamRecruitmentCenterScreen()),
                        onMapTap: () => _openPage(const CampusMapTabPage()),
                        onCalendarTap: () =>
                            _openPage(const CampusCalendarScreen()),
                      ),
                    ),
                    const SizedBox(height: 12),
                    CampusNewsSectionHeader(
                      isDark: isDark,
                      onCompetitionTap: () =>
                          _openPage(const CompetitionCenterScreen()),
                    ),
                    const SizedBox(height: 6),
                  ]),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 126),
                sliver: SliverToBoxAdapter(
                  child: _buildRecentList(isDark),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 最新文章卡片 ───────────────────────────────────────────────

  Widget _buildLatestCard(bool isDark) {
    // 最新文章加载中
    if (!_latestLoaded) {
      return _LatestCardSkeleton(isDark: isDark);
    }

    final latest = _displayLatest;

    // 有数据 → 显示真实卡片
    if (latest != null) {
      return CampusFeatureNoticeCard(
        article: latest,
        isDark: isDark,
        onTap: () => _openArticleDetail(latest),
      );
    }

    // 最新失败且列表也失败或为空
    if (_latestError != null &&
        (_recentError != null || _recentArticles.isEmpty)) {
      return _LatestCardError(
        message: _latestError ?? '加载失败',
        isDark: isDark,
        onRetry: _loadAll,
      );
    }

    // 最新失败但列表还在加载 → 显示骨架屏
    if (_latestError != null && !_recentLoaded) {
      return _LatestCardSkeleton(isDark: isDark);
    }

    // 最新失败但列表有数据 → _displayLatest 会返回列表第一条
    // 如果走到这里说明列表也为空
    if (latest == null) {
      return _LatestCardEmpty(isDark: isDark);
    }

    // 兜底
    return _LatestCardSkeleton(isDark: isDark);
  }

  // ── 最近文章列表 ───────────────────────────────────────────────

  Widget _buildRecentList(bool isDark) {
    // 最近列表加载中（独立于最新文章的加载状态）
    if (!_recentLoaded) {
      return _RecentListSkeleton(isDark: isDark);
    }

    final recent = _displayRecent;

    // 列表加载失败但最新成功
    if (_recentError != null && _displayLatest != null) {
      return _RecentListError(
        message: _recentError!,
        isDark: isDark,
        onRetry: _loadAll,
      );
    }

    // 列表加载失败且最新也失败
    if (_recentError != null && _displayLatest == null) {
      // 已在上方卡片显示错误，这里不再重复
      return const SizedBox.shrink();
    }

    // 空数据
    if (recent.isEmpty && _displayLatest == null) {
      return _RecentListEmpty(isDark: isDark);
    }

    if (recent.isEmpty) {
      // 只有最新文章，没有更多
      return _buildViewAllLink(isDark);
    }

    return Column(
      children: [
        for (final article in recent) ...[
          CampusNewsCard(
            article: article,
            isDark: isDark,
            onTap: () => _openArticleDetail(article),
          ),
          const SizedBox(height: 10),
        ],
        _buildViewAllLink(isDark),
      ],
    );
  }

  Widget _buildViewAllLink(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () => _openPage(const CampusArticleListScreen()),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 32),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '查看全部校园资讯',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: isDark ? Colors.white38 : Colors.black45,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 最新文章骨架屏。
class _LatestCardSkeleton extends StatelessWidget {
  final bool isDark;
  const _LatestCardSkeleton({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final shimmerColor = isDark ? Colors.white10 : CampusTheme.softBorder;

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 112),
      child: Container(
        width: double.infinity,
        clipBehavior: Clip.antiAlias,
        decoration: CampusTheme.cardDecoration(isDark, softGreen: true),
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 80,
                  height: 24,
                  decoration: BoxDecoration(
                    color: shimmerColor,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                const Spacer(),
                Container(
                  width: 40,
                  height: 24,
                  decoration: BoxDecoration(
                    color: shimmerColor,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 22,
              decoration: BoxDecoration(
                color: shimmerColor,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 7),
            Container(
              width: 180,
              height: 14,
              decoration: BoxDecoration(
                color: shimmerColor,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 最新文章错误状态。
class _LatestCardError extends StatelessWidget {
  final String message;
  final bool isDark;
  final VoidCallback onRetry;

  const _LatestCardError({
    required this.message,
    required this.isDark,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: CampusTheme.cardDecoration(isDark),
      child: Column(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 36,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onRetry,
            child: const Text('点击重试'),
          ),
        ],
      ),
    );
  }
}

/// 最新文章空状态。
class _LatestCardEmpty extends StatelessWidget {
  final bool isDark;
  const _LatestCardEmpty({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: CampusTheme.cardDecoration(isDark),
      child: Column(
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 36,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
          const SizedBox(height: 10),
          Text(
            '暂无校园资讯',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }
}

/// 最近列表骨架屏。
class _RecentListSkeleton extends StatelessWidget {
  final bool isDark;
  const _RecentListSkeleton({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final shimmerColor = isDark ? Colors.white10 : const Color(0xFFEDEBF3);
    return Column(
      children: [
        for (int i = 0; i < 3; i++) ...[
          Container(
            height: 90,
            padding: const EdgeInsets.all(14),
            decoration: CampusTheme.cardDecoration(isDark),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 60,
                  height: 14,
                  decoration: BoxDecoration(
                    color: shimmerColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 16,
                  decoration: BoxDecoration(
                    color: shimmerColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// 最近列表错误状态。
class _RecentListError extends StatelessWidget {
  final String message;
  final bool isDark;
  final VoidCallback onRetry;

  const _RecentListError({
    required this.message,
    required this.isDark,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: CampusTheme.cardDecoration(isDark),
      child: Column(
        children: [
          Icon(
            Icons.cloud_off_rounded,
            size: 36,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: onRetry,
            child: const Text('点击重试'),
          ),
        ],
      ),
    );
  }
}

/// 最近列表空状态。
class _RecentListEmpty extends StatelessWidget {
  final bool isDark;
  const _RecentListEmpty({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: CampusTheme.cardDecoration(isDark),
      child: Column(
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 36,
            color: isDark ? Colors.white38 : Colors.black38,
          ),
          const SizedBox(height: 10),
          Text(
            '暂无校园资讯',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white54 : Colors.black54,
            ),
          ),
        ],
      ),
    );
  }
}
