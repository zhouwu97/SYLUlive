import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_bootstrap.dart';
import '../models/campus_article.dart';
import '../models/ai_capabilities.dart';
import '../services/ai_assistant_service.dart';
import '../services/campus_article_service.dart';
import '../widgets/home_tab_reveal.dart';
import '../utils/campus_asset_preloader.dart';

import '../widgets/campus/campus_theme.dart';
import '../widgets/campus/campus_ai_entry_card.dart';
import '../widgets/campus/campus_header.dart';
import '../widgets/campus/campus_feature_notice_card.dart';
import '../widgets/campus/campus_service_grid.dart';
import '../widgets/campus/campus_news_section_header.dart';
import '../widgets/campus/campus_news_card.dart';

import 'campus_article_detail_screen.dart';
import 'ai/ai_assistant_screen.dart';
import 'campus_article_list_screen.dart';
import 'campus_calendar_screen.dart';
import 'campus_map_tab_page.dart';
import 'competition_center_screen.dart';
import 'edu_screen.dart';
import 'teacher_rate_screen.dart';
import 'team/team_recruitment_center_screen.dart';

class CampusScreen extends StatefulWidget {
  /// 可选依赖仅用于测试；生产环境继续复用全局 Dio 与鉴权头。
  final CampusArticleService? articleService;
  final AiAssistantService? aiService;

  const CampusScreen({super.key, this.articleService, this.aiService});

  @override
  State<CampusScreen> createState() => _CampusScreenState();
}

class _CampusScreenState extends State<CampusScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late CampusArticleService _articleService;
  late AiAssistantService _aiService;
  AiCapabilities? _aiCapabilities;

  // 最新文章
  CampusArticleSummary? _latestArticle;
  String? _latestError;
  bool _latestLoaded = false;

  // 最近文章列表
  List<CampusArticleSummary> _recentArticles = [];
  String? _recentError;
  bool _recentLoaded = false;
  bool _assetsPreloaded = false;

  Future<void>? _loadFuture;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    final dio = getSharedDio();
    _articleService = widget.articleService ?? CampusArticleService(dio);
    _aiService = widget.aiService ?? AiAssistantService(dio);
    _loadAll();
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
    if (force) _loadFuture = null;
    if (_loadFuture != null) return _loadFuture!;
    final generation = ++_loadGeneration;
    _loadFuture = Future.wait([
      _loadLatest(generation),
      _loadRecent(generation),
      _loadAiCapabilities(generation),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${isLatest ? '头条' : '资讯'}刷新失败: $message')),
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
                    const SizedBox(height: 10),
                    HomeTabRevealItem(
                      index: 1,
                      child: _buildLatestCard(isDark),
                    ),
                    if (_aiCapabilities != null) ...[
                      const SizedBox(height: 12),
                      HomeTabRevealItem(
                        index: 2,
                        child: CampusAiEntryCard(
                          capabilities: _aiCapabilities!,
                          isDark: isDark,
                          onTap: _openAiAssistant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    HomeTabRevealItem(
                      index: _aiCapabilities == null ? 2 : 3,
                      child: CampusServiceGrid(
                        isDark: isDark,
                        onEduTap: () => _openPage(const EduScreen()),
                        onRateTap: () => _openPage(const TeacherRateScreen()),
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
