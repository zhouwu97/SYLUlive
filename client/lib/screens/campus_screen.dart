import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../models/campus_article.dart';
import '../services/campus_article_service.dart';
import '../widgets/home_tab_reveal.dart';
import 'campus_article_detail_screen.dart';
import 'campus_article_list_screen.dart';
import 'campus_calendar_screen.dart';
import 'campus_map_tab_page.dart';
import 'competition_center_screen.dart';
import 'edu_screen.dart';
import 'teacher_rate_screen.dart';

class CampusScreen extends StatefulWidget {
  const CampusScreen({super.key});

  @override
  State<CampusScreen> createState() => _CampusScreenState();
}

class _CampusScreenState extends State<CampusScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late CampusArticleService _articleService;

  // 最新文章
  CampusArticleSummary? _latestArticle;
  String? _latestError;
  bool _latestLoaded = false;

  // 最近文章列表
  List<CampusArticleSummary> _recentArticles = [];
  String? _recentError;
  bool _recentLoaded = false;

  @override
  void initState() {
    super.initState();
    _articleService = CampusArticleService(getSharedDio());
    _loadAll();
  }

  /// 并行加载最新文章和最近列表。
  Future<void> _loadAll() async {
    await Future.wait([
      _loadLatest(),
      _loadRecent(),
    ]);
  }

  Future<void> _loadLatest() async {
    try {
      final article = await _articleService.getLatestArticle();
      if (mounted) {
        setState(() {
          _latestArticle = article;
          _latestError = null;
          _latestLoaded = true;
        });
      }
    } on CampusArticleServiceException catch (e) {
      if (mounted) {
        setState(() {
          _latestError = e.message;
          _latestLoaded = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _latestError = '加载失败';
          _latestLoaded = true;
        });
      }
    }
  }

  Future<void> _loadRecent() async {
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

      if (mounted) {
        setState(() {
          _recentArticles = merged;
          _recentError = null;
          _recentLoaded = true;
        });
      }
    } on CampusArticleServiceException catch (e) {
      if (mounted) {
        setState(() {
          _recentError = e.message;
          _recentLoaded = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _recentError = '加载失败';
          _recentLoaded = true;
        });
      }
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
      backgroundColor:
          isDark ? const Color(0xFF101219) : const Color(0xFFF8F7FC),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _loadAll,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 156),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    HomeTabRevealItem(
                      index: 0,
                      child: _CampusHeader(semester: _currentSemesterText()),
                    ),
                    const SizedBox(height: 18),
                    HomeTabRevealItem(
                      index: 1,
                      child: _buildLatestCard(isDark),
                    ),
                    const SizedBox(height: 24),
                    const HomeTabRevealItem(
                      index: 2,
                      child: _SectionTitle(
                        title: '校园服务',
                        subtitle: '常用校园功能',
                      ),
                    ),
                    const SizedBox(height: 12),
                    HomeTabRevealItem(
                      index: 3,
                      child: _buildServiceRow(isDark),
                    ),
                    const SizedBox(height: 26),
                    HomeTabRevealItem(
                      index: 4,
                      child: _CampusInfoSectionTitle(
                        title: '校园资讯',
                        subtitle: '校内通知与赛事信息',
                        onCompetitionTap: () =>
                            _openPage(const CompetitionCenterScreen()),
                      ),
                    ),
                    const SizedBox(height: 12),
                    HomeTabRevealItem(
                      index: 5,
                      child: _buildRecentList(isDark),
                    ),
                  ]),
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
      return _LatestArticleCard(
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
          _RecentArticleItem(
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

  Widget _buildServiceRow(bool isDark) {
    final services = <_CampusService>[
      _CampusService(
        title: '教务中心',
        icon: Icons.school_rounded,
        color: const Color(0xFF5D64C4),
        onTap: () => _openPage(const EduScreen()),
      ),
      _CampusService(
        title: '校园榜单',
        icon: Icons.leaderboard_rounded,
        color: const Color(0xFFF29A3F),
        onTap: () => _openPage(const TeacherRateScreen()),
      ),
      _CampusService(
        title: '校园地图',
        icon: Icons.map_rounded,
        color: const Color(0xFF3E92CC),
        onTap: () => _openPage(const CampusMapTabPage()),
      ),
      _CampusService(
        title: '校历',
        icon: Icons.calendar_month_rounded,
        color: const Color(0xFF40A578),
        onTap: () => _openPage(const CampusCalendarScreen()),
      ),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < services.length; index++) ...[
          Expanded(
            child: _CampusServiceCard(
              service: services[index],
              isDark: isDark,
            ),
          ),
          if (index != services.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  保留的现有组件
// ════════════════════════════════════════════════════════════════

class _CampusHeader extends StatelessWidget {
  final String semester;

  const _CampusHeader({required this.semester});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '校园',
                style: TextStyle(
                  fontSize: 27,
                  height: 1.1,
                  fontWeight: FontWeight.w900,
                  color: isDark ? Colors.white : const Color(0xFF20212B),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                semester,
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? Colors.white54 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
        Icon(
          Icons.account_balance_rounded,
          size: 28,
          color: primary.withValues(alpha: 0.72),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionTitle({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: isDark ? Colors.white : const Color(0xFF242530),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white54 : Colors.black45,
          ),
        ),
      ],
    );
  }
}

class _CampusInfoSectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onCompetitionTap;

  const _CampusInfoSectionTitle({
    required this.title,
    required this.subtitle,
    required this.onCompetitionTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: isDark ? Colors.white : const Color(0xFF242530),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Material(
          color: isDark
              ? primary.withValues(alpha: 0.18)
              : primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: onCompetitionTap,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: primary.withValues(alpha: isDark ? 0.22 : 0.14),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.emoji_events_rounded,
                    size: 16,
                    color: primary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '竞赛中心',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CampusService {
  final String title;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _CampusService({
    required this.title,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

class _CampusServiceCard extends StatelessWidget {
  final _CampusService service;
  final bool isDark;

  const _CampusServiceCard({
    required this.service,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isDark ? const Color(0xFF1B1E28) : Colors.white,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        onTap: service.onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          height: 92,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: service.color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  service.icon,
                  color: service.color,
                  size: 21,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                service.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.2,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : const Color(0xFF292A35),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  最新文章卡片（替代 _SchoolNoticePlaceholder）
// ════════════════════════════════════════════════════════════════

/// 最新文章卡片，保留紫色渐变视觉风格。
class _LatestArticleCard extends StatelessWidget {
  final CampusArticleSummary article;
  final bool isDark;
  final VoidCallback onTap;

  const _LatestArticleCard({
    required this.article,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final endColor =
        Color.lerp(primary, const Color(0xFF8B79C6), 0.58) ?? primary;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [primary, endColor],
          ),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: primary.withValues(alpha: isDark ? 0.16 : 0.22),
              blurRadius: 22,
              offset: const Offset(0, 9),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              right: -18,
              top: -18,
              child: Icon(
                Icons.account_balance_rounded,
                size: 128,
                color: Colors.white.withValues(alpha: 0.075),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 15, 18, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.17),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.campaign_rounded,
                              size: 14,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              article.category.isNotEmpty
                                  ? article.category
                                  : '教务通知',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          article.publishDate.isNotEmpty
                              ? article.shortDate
                              : '最新',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.82),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 13),
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      height: 1.28,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (article.authorDepartment.isNotEmpty)
                        article.authorDepartment,
                      if (article.publishDate.isNotEmpty) article.publishDate,
                      if (article.hasAttachment) '含附件',
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: Colors.white.withValues(alpha: 0.72),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
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
    final primary = Theme.of(context).colorScheme.primary;
    final endColor =
        Color.lerp(primary, const Color(0xFF8B79C6), 0.58) ?? primary;
    final shimmerColor = Colors.white.withValues(alpha: 0.15);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [primary, endColor],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
        child: Column(
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
            const SizedBox(height: 16),
            Container(
              height: 22,
              decoration: BoxDecoration(
                color: shimmerColor,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 8),
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
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
        ),
      ),
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
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
        ),
      ),
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

// ════════════════════════════════════════════════════════════════
//  最近文章列表项（替代 _CampusArticlePlaceholder）
// ════════════════════════════════════════════════════════════════

class _RecentArticleItem extends StatelessWidget {
  final CampusArticleSummary article;
  final bool isDark;
  final VoidCallback onTap;

  const _RecentArticleItem({
    required this.article,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Material(
      color: isDark ? const Color(0xFF1B1E28) : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 分类 + 日期
              Row(
                children: [
                  Text(
                    article.category.isNotEmpty ? article.category : '校园资讯',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: article.source == 'cxcy'
                          ? const Color(0xFFE89B30)
                          : primary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    article.shortDate,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white38 : Colors.black45,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 标题（最多两行）
              Text(
                article.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF292A35),
                ),
              ),
              const SizedBox(height: 6),
              // 部门 · 附件状态
              Row(
                children: [
                  if (article.authorDepartment.isNotEmpty) ...[
                    Flexible(
                      child: Text(
                        article.authorDepartment,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white38 : Colors.black45,
                        ),
                      ),
                    ),
                  ],
                  if (article.authorDepartment.isNotEmpty &&
                      article.hasAttachment) ...[
                    Text(
                      ' · ',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white24 : Colors.black26,
                      ),
                    ),
                  ],
                  if (article.hasAttachment) ...[
                    Icon(
                      Icons.attach_file_rounded,
                      size: 13,
                      color: isDark ? Colors.white38 : Colors.black45,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '含附件',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white38 : Colors.black45,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
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
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1B1E28) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: shimmerColor),
            ),
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
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
        ),
      ),
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
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B1E28) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white10 : const Color(0xFFEDEBF3),
        ),
      ),
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
