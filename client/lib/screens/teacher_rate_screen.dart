import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../config/api_constants.dart';
import '../models/teacher.dart';
import '../providers/auth_provider.dart';
import '../providers/canteen_provider.dart';
import '../providers/major_provider.dart';
import '../providers/teacher_provider.dart';
import '../utils/responsive_util.dart';
import '../widgets/image_upload_widget.dart';
import '../widgets/rating_detail/ranking_tokens.dart';
import 'canteen_detail_screen.dart';
import 'major_detail_screen.dart';
import 'subject_ranking_detail_screen.dart';

class TeacherRateScreen extends StatefulWidget {
  const TeacherRateScreen({super.key});

  @override
  State<TeacherRateScreen> createState() => _TeacherRateScreenState();
}

class _TeacherRateScreenState extends State<TeacherRateScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  final _searchCtrl = TextEditingController();
  bool _showDisclaimer = false;

  @override
  void initState() {
    super.initState();
    _checkDisclaimer();
    _tabCtrl = TabController(length: 3, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAll());
  }

  Future<void> _checkDisclaimer() async {
    final prefs = await SharedPreferences.getInstance();
    final hasShown = prefs.getBool('has_shown_teacher_disclaimer') ?? false;
    if (!hasShown) {
      if (mounted) setState(() => _showDisclaimer = true);
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      context.read<TeacherProvider>().loadTeachers(query: _currentQuery),
      context.read<MajorProvider>().loadMajors(),
      context.read<CanteenProvider>().loadCanteens(),
    ]);
  }

  String? get _currentQuery {
    final query = _searchCtrl.text.trim();
    return query.isEmpty ? null : query;
  }

  // ── per-tab accent helpers ─────────────────────────────────────────

  Color _tabAccent(bool isDark) => switch (_tabCtrl.index) {
        0 => RankingTokens.canteenAccent(isDark),
        1 => RankingTokens.teacherAccent(isDark),
        _ => RankingTokens.majorAccent(isDark),
      };

  Color _tabAccentSoft(bool isDark) => switch (_tabCtrl.index) {
        0 => RankingTokens.canteenAccentSoft(isDark),
        1 => RankingTokens.teacherAccentSoft(isDark),
        _ => RankingTokens.majorAccentSoft(isDark),
      };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = _tabAccent(isDark);

    return Scaffold(
      backgroundColor: RankingTokens.pageBg(isDark),
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          '校园榜单',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: RankingTokens.pageBg(isDark),
        surfaceTintColor: Colors.transparent,
        foregroundColor: RankingTokens.titleColor(isDark),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_tabCtrl.index == 1 && _showDisclaimer)
                _buildDisclaimer(isDark),
              _buildSearchBar(isDark),
              _buildSegmentedControl(isDark),
              Expanded(
                child: _tabCtrl.index == 0
                    ? _buildCanteenList(isDark)
                    : (_tabCtrl.index == 1
                        ? _buildSubjectList(isDark)
                        : _buildMajorList(isDark)),
              ),
            ],
          ),
          Positioned(right: 20, bottom: 20, child: _buildFAB(isDark, accent)),
        ],
      ),
    );
  }

  // ── Segmented control ──────────────────────────────────────────────

  Widget _buildSegmentedControl(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        height: RankingTokens.tabHeight,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : const Color(0xFFF3F2EF),
        ),
        child: Row(
          children: [
            Expanded(child: _buildSegmentItem(0, '食堂榜', isDark)),
            Expanded(child: _buildSegmentItem(1, '学科榜', isDark)),
            Expanded(child: _buildSegmentItem(2, '专业榜', isDark)),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentItem(int index, String label, bool isDark) {
    final isSelected = _tabCtrl.index == index;
    final accent = switch (index) {
      0 => RankingTokens.canteenAccent(isDark),
      1 => RankingTokens.teacherAccent(isDark),
      _ => RankingTokens.majorAccent(isDark),
    };
    final accentSoft = switch (index) {
      0 => RankingTokens.canteenAccentSoft(isDark),
      1 => RankingTokens.teacherAccentSoft(isDark),
      _ => RankingTokens.majorAccentSoft(isDark),
    };

    return GestureDetector(
      onTap: () {
        _tabCtrl.animateTo(index);
        setState(() {});
      },
      child: Container(
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected ? accentSoft : Colors.transparent,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: isSelected
                ? accent
                : (isDark ? Colors.white54 : Colors.black54),
          ),
        ),
      ),
    );
  }

  // ── FAB ────────────────────────────────────────────────────────────

  String get _fabLabel => switch (_tabCtrl.index) {
        0 => '添加食堂',
        1 => '添加教师',
        _ => '添加专业',
      };

  Widget _buildFAB(bool isDark, Color accent) {
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSafe > 0 ? bottomSafe : 0),
      child: FloatingActionButton.extended(
        heroTag: 'teacher_rate_fab',
        onPressed: _showAddDialog,
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: const Icon(Icons.add_rounded, color: Colors.white, size: 20),
        label: Text(
          _fabLabel,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  // ── Disclaimer ─────────────────────────────────────────────────────

  Widget _buildDisclaimer(bool isDark) => Container(
        margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: RankingTokens.teacherAccentSoft(isDark),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: RankingTokens.teacherAccent(isDark).withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.info_outline,
              size: 18,
              color: RankingTokens.teacherAccent(isDark),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '教师榜已按学科聚合。添加教师时请填写完整课程名称，例如"数据结构""高等数学A1"，避免同一学科被拆散。',
                style: TextStyle(
                  fontSize: 12,
                  color: RankingTokens.subColor(isDark),
                  height: 1.4,
                ),
              ),
            ),
            GestureDetector(
              onTap: () async {
                if (mounted) setState(() => _showDisclaimer = false);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('has_shown_teacher_disclaimer', true);
              },
              child: Icon(Icons.close, size: 16, color: RankingTokens.subColor(isDark)),
            ),
          ],
        ),
      );

  // ── Search bar ─────────────────────────────────────────────────────

  Widget _buildSearchBar(bool isDark) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Container(
          height: RankingTokens.searchHeight,
          decoration: BoxDecoration(
            color: RankingTokens.cardBg(isDark),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: RankingTokens.borderColor(isDark)),
          ),
          child: TextField(
            controller: _searchCtrl,
            style: TextStyle(
              fontSize: 14,
              color: RankingTokens.titleColor(isDark),
            ),
            decoration: InputDecoration(
              hintText: _tabCtrl.index == 0
                  ? '搜索食堂...'
                  : (_tabCtrl.index == 1 ? '搜索学科或教师...' : '搜索专业...'),
              hintStyle: TextStyle(
                fontSize: 14,
                color: RankingTokens.mutedColor(isDark),
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 20,
                color: RankingTokens.subColor(isDark),
              ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 40, minHeight: 40),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onChanged: (value) {
              if (_tabCtrl.index == 1) {
                context.read<TeacherProvider>().loadTeachers(
                      query: value.trim().isEmpty ? null : value,
                    );
              } else {
                setState(() {});
              }
            },
          ),
        ),
      );

  // ── Subject list ───────────────────────────────────────────────────

  Widget _buildSubjectList(bool isDark) => Consumer<TeacherProvider>(
        builder: (_, provider, __) {
          if (provider.isLoading && provider.teachers.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }

          final groups = _buildSubjectGroups(provider.teachers, _currentQuery);
          if (groups.isEmpty) {
            return Center(
              child: Text(
                '暂无学科数据',
                style: TextStyle(color: RankingTokens.subColor(isDark)),
              ),
            );
          }

          Widget buildCard(int index) {
            final group = groups[index];
            final topTeachers =
                group.teachers.take(3).map((t) => t.name).join(' · ');
            return _buildLeaderboardCard(
              isDark: isDark,
              rank: index + 1,
              title: group.subject,
              subtitle: topTeachers.isEmpty ? '暂无教师' : '代表教师 · $topTeachers',
              average: group.averageStar,
              count: group.ratingCount,
              extraLabel: '${group.teachers.length} 位教师',
              icon: Icons.auto_stories_outlined,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SubjectRankingDetailScreen(
                    subjectName: group.subject,
                    teachers: group.teachers,
                  ),
                ),
              ).then((changed) async {
                if (changed != true || !mounted) return;
                await context.read<TeacherProvider>().loadTeachers(
                      query: _currentQuery,
                    );
              }),
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              await context.read<TeacherProvider>().loadTeachers(
                    query: _currentQuery,
                  );
            },
            child: ResponsiveUtil.isDesktop(context)
                ? MasonryGridView.count(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
                    crossAxisCount:
                        MediaQuery.of(context).size.width > 900 ? 3 : 2,
                    mainAxisSpacing: RankingTokens.cardGap,
                    crossAxisSpacing: RankingTokens.cardGap,
                    itemCount: groups.length,
                    itemBuilder: (_, index) => buildCard(index),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                    itemCount: groups.length,
                    itemBuilder: (_, index) => buildCard(index),
                  ),
          );
        },
      );

  // ── Major list ─────────────────────────────────────────────────────

  Widget _buildMajorList(bool isDark) => Consumer<MajorProvider>(
        builder: (_, provider, __) {
          final query = _currentQuery?.toLowerCase();
          final majors = query == null
              ? provider.majors
              : provider.majors
                  .where((m) => m.name.toLowerCase().contains(query))
                  .toList();

          if (provider.isLoading && provider.majors.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (majors.isEmpty) {
            return Center(
              child: Text(
                '暂无专业',
                style: TextStyle(color: RankingTokens.subColor(isDark)),
              ),
            );
          }

          Widget buildCard(int index) {
            final major = majors[index];
            return _buildLeaderboardCard(
              isDark: isDark,
              rank: index + 1,
              title: major.name,
              subtitle: major.level,
              average: major.averageStar,
              count: major.ratingCount,
              extraLabel: '专业评分',
              icon: Icons.school_outlined,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MajorDetailScreen(
                    majorId: major.id,
                    majorName: major.name,
                  ),
                ),
              ).then((_) {
                if (!mounted) return;
                context.read<MajorProvider>().loadMajors();
              }),
            );
          }

          return RefreshIndicator(
            onRefresh: () => context.read<MajorProvider>().loadMajors(),
            child: ResponsiveUtil.isDesktop(context)
                ? MasonryGridView.count(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
                    crossAxisCount:
                        MediaQuery.of(context).size.width > 900 ? 3 : 2,
                    mainAxisSpacing: RankingTokens.cardGap,
                    crossAxisSpacing: RankingTokens.cardGap,
                    itemCount: majors.length,
                    itemBuilder: (_, index) => buildCard(index),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
                    itemCount: majors.length,
                    itemBuilder: (_, index) => buildCard(index),
                  ),
          );
        },
      );

  // ── Leaderboard card (compact, shared) ─────────────────────────────

  Widget _buildLeaderboardCard({
    required bool isDark,
    required int rank,
    required String title,
    required String subtitle,
    required double average,
    required int count,
    required String extraLabel,
    required IconData icon,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    String? imageUrl,
  }) {
    final accent = _tabAccent(isDark);
    final accentSoft = _tabAccentSoft(isDark);
    final hasImage = imageUrl != null && imageUrl.isNotEmpty;
    final rankColor = _rankColor(rank - 1);

    return Padding(
      padding: EdgeInsets.only(bottom: RankingTokens.cardGap),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(RankingTokens.cardRadius),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: RankingTokens.cardDecoration(isDark),
            child: Row(
              children: [
                // Left: image / icon + rank badge
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: hasImage ? null : accentSoft,
                          borderRadius: BorderRadius.circular(14),
                          image: hasImage
                              ? DecorationImage(
                                  image: CachedNetworkImageProvider(imageUrl),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: hasImage
                            ? null
                            : Icon(icon, color: accent, size: 22),
                      ),
                      Positioned(
                        top: -4,
                        left: -4,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: rankColor,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: [
                              BoxShadow(
                                color: rankColor.withValues(alpha: 0.4),
                                blurRadius: 3,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '$rank',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: RankingTokens.titleColor(isDark),
                        ),
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: RankingTokens.subColor(isDark),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _buildMetricChip(
                            isDark,
                            Icons.star_rounded,
                            average.toStringAsFixed(1),
                            accent,
                          ),
                          const SizedBox(width: 6),
                          _buildMetricChip(
                            isDark,
                            Icons.rate_review_outlined,
                            '$count 条评价',
                            accent,
                          ),
                          if (extraLabel.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            _buildMetricChip(
                              isDark,
                              Icons.layers_outlined,
                              extraLabel,
                              accent,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: RankingTokens.subColor(isDark),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMetricChip(
    bool isDark,
    IconData icon,
    String text,
    Color accent,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: accent),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: RankingTokens.subColor(isDark),
            ),
          ),
        ],
      ),
    );
  }

  List<_SubjectGroup> _buildSubjectGroups(
    List<Teacher> teachers,
    String? query,
  ) {
    final keyword = query?.trim().toLowerCase();
    final map = <String, List<Teacher>>{};

    for (final teacher in teachers) {
      final subject =
          teacher.course.trim().isEmpty ? '未分类课程' : teacher.course.trim();
      final hit = keyword == null ||
          subject.toLowerCase().contains(keyword) ||
          teacher.name.toLowerCase().contains(keyword);
      if (!hit) continue;
      map.putIfAbsent(subject, () => <Teacher>[]).add(teacher);
    }

    final groups = map.entries.map((entry) {
      final items = [...entry.value]..sort((a, b) {
          final compare = b.averageStar.compareTo(a.averageStar);
          if (compare != 0) return compare;
          return b.ratingCount.compareTo(a.ratingCount);
        });
      return _SubjectGroup(entry.key, items);
    }).toList();

    groups.sort((a, b) {
      final compare = b.averageStar.compareTo(a.averageStar);
      if (compare != 0) return compare;
      final countCompare = b.ratingCount.compareTo(a.ratingCount);
      if (countCompare != 0) return countCompare;
      return a.subject.compareTo(b.subject);
    });
    return groups;
  }

  // ── Canteen list ───────────────────────────────────────────────────

  Widget _buildCanteenList(bool isDark) {
    final user = context.watch<AuthProvider>().user;
    final isAdmin = user?.role == 'admin' || user?.role == 'super_admin';

    return Consumer<CanteenProvider>(
      builder: (_, provider, __) {
        final query = _currentQuery?.toLowerCase();
        final canteens = query == null
            ? provider.canteens
            : provider.canteens
                .where((m) => m.name.toLowerCase().contains(query))
                .toList();

        if (provider.isLoading && provider.canteens.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (canteens.isEmpty) {
          return Center(
            child: Text(
              '暂无食堂',
              style: TextStyle(color: RankingTokens.subColor(isDark)),
            ),
          );
        }

        Widget buildCard(int index) {
          final canteen = canteens[index];
          return _buildLeaderboardCard(
            isDark: isDark,
            rank: index + 1,
            title: canteen.name,
            subtitle: '',
            average: canteen.averageStar,
            count: canteen.ratingCount,
            extraLabel: '',
            icon: Icons.restaurant,
            imageUrl: canteen.image.isNotEmpty
                ? ApiConstants.fullUrl(canteen.image)
                : null,
            onLongPress: isAdmin
                ? () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('删除店铺'),
                        content: Text('确定要删除食堂/店铺 "${canteen.name}" 吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () async {
                              Navigator.pop(ctx);
                              final success = await context
                                  .read<CanteenProvider>()
                                  .deleteCanteen(canteen.id);
                              if (success && mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('删除成功')),
                                );
                                context.read<CanteenProvider>().loadCanteens();
                              }
                            },
                            child: const Text(
                              '删除',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                : null,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CanteenDetailScreen(
                  canteenId: canteen.id,
                  canteenName: canteen.name,
                ),
              ),
            ).then((_) {
              if (!mounted) return;
              context.read<CanteenProvider>().loadCanteens();
            }),
          );
        }

        return RefreshIndicator(
          onRefresh: () => context.read<CanteenProvider>().loadCanteens(),
          child: ResponsiveUtil.isDesktop(context)
              ? MasonryGridView.count(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 104),
                  crossAxisCount:
                      MediaQuery.of(context).size.width > 900 ? 3 : 2,
                  mainAxisSpacing: RankingTokens.cardGap,
                  crossAxisSpacing: RankingTokens.cardGap,
                  itemCount: canteens.length,
                  itemBuilder: (_, index) => buildCard(index),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
                  itemCount: canteens.length,
                  itemBuilder: (_, index) => buildCard(index),
                ),
        );
      },
    );
  }

  // ── Add canteen sheet ──────────────────────────────────────────────

  Future<void> _showAddCanteenSheet() async {
    final nameCtrl = TextEditingController();
    List<String> uploadedImageUrls = [];
    var submitting = false;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = RankingTokens.canteenAccent(isDark);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModalState) {
            final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
            return Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Container(
                decoration: BoxDecoration(
                  color: RankingTokens.cardBg(isDark),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(28)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: RankingTokens.borderColor(isDark),
                            borderRadius: BorderRadius.circular(99),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: RankingTokens.canteenAccentSoft(isDark),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Icon(
                              Icons.storefront_rounded,
                              color: accent,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '添加食堂',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: RankingTokens.titleColor(isDark),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '填写名称并上传一张店铺图片',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: RankingTokens.subColor(isDark),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      TextField(
                        controller: nameCtrl,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                          hintText: '请输入食堂 / 店铺名',
                          hintStyle: TextStyle(
                            color: RankingTokens.subColor(isDark),
                          ),
                          prefixIcon:
                              const Icon(Icons.restaurant_rounded),
                          filled: true,
                          fillColor: RankingTokens.pageBg(isDark),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide:
                                BorderSide(color: RankingTokens.borderColor(isDark)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide:
                                BorderSide(color: RankingTokens.borderColor(isDark)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: accent, width: 1.4),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ImageUploadWidget(
                        maxImages: 1,
                        largeCard: true,
                        emptyTitle: '添加图片',
                        emptySubtitle: '建议上传店铺门面或招牌图',
                        onImagesUploaded: (urls) {
                          uploadedImageUrls = urls;
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: submitting
                                  ? null
                                  : () => Navigator.pop(sheetContext),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(48),
                                side: BorderSide(
                                  color: RankingTokens.borderColor(isDark),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: submitting
                                  ? null
                                  : () async {
                                      final name = nameCtrl.text.trim();
                                      if (name.isEmpty) {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('请输入食堂 / 店铺名'),
                                          ),
                                        );
                                        return;
                                      }
                                      if (uploadedImageUrls.isEmpty) {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('请上传一张食堂封面图片'),
                                          ),
                                        );
                                        return;
                                      }

                                      setModalState(() => submitting = true);
                                      final success = await context
                                          .read<CanteenProvider>()
                                          .addCanteen(
                                            name,
                                            uploadedImageUrls.first,
                                          );
                                      if (!mounted || !sheetContext.mounted) {
                                        return;
                                      }
                                      setModalState(() => submitting = false);
                                      if (success) {
                                        Navigator.pop(sheetContext);
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('添加成功，经验+10'),
                                          ),
                                        );
                                        await context
                                            .read<CanteenProvider>()
                                            .loadCanteens();
                                      } else {
                                        ScaffoldMessenger.of(sheetContext)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text('添加失败，请稍后重试'),
                                          ),
                                        );
                                      }
                                    },
                              style: FilledButton.styleFrom(
                                backgroundColor: accent,
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(48),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: submitting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('提交'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    nameCtrl.dispose();
  }

  // ── Add dialog (teacher / major) ───────────────────────────────────

  Future<void> _showAddDialog() async {
    if (_tabCtrl.index == 0) {
      await _showAddCanteenSheet();
      return;
    }

    final nameCtrl = TextEditingController();
    final courseCtrl = TextEditingController();
    final levelCtrl = TextEditingController(text: '本科');
    final isTeacher = _tabCtrl.index == 1;
    final isMajor = _tabCtrl.index == 2;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isTeacher ? '添加教师' : (isMajor ? '添加专业' : '添加食堂')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText:
                    isTeacher ? '教师姓名' : (isMajor ? '专业名' : '食堂/店铺名'),
              ),
            ),
            const SizedBox(height: 8),
            if (isTeacher)
              TextField(
                controller: courseCtrl,
                decoration: const InputDecoration(
                  labelText: '课程名称',
                  helperText: '请填写完整课程名称，学科榜会按这里的文字聚合',
                ),
              )
            else if (isMajor)
              DropdownButtonFormField(
                initialValue: '本科',
                items: const [
                  DropdownMenuItem(value: '本科', child: Text('本科')),
                  DropdownMenuItem(value: '研究生', child: Text('研究生')),
                ],
                onChanged: (v) => levelCtrl.text = v!,
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final course = courseCtrl.text.trim();
              if (name.isEmpty) return;

              if (isTeacher && course.length < 2) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('请填写完整课程名称')));
                return;
              }

              Navigator.pop(ctx);

              if (isTeacher) {
                await context.read<TeacherProvider>().addTeacher(name, course);
                if (!mounted) return;
                await context.read<TeacherProvider>().loadTeachers(
                      query: _currentQuery,
                    );
              } else if (isMajor) {
                await context.read<MajorProvider>().addMajor(
                      name,
                      levelCtrl.text,
                    );
                if (!mounted) return;
                await context.read<MajorProvider>().loadMajors();
              }
            },
            child: const Text('提交'),
          ),
        ],
      ),
    );

    nameCtrl.dispose();
    courseCtrl.dispose();
    levelCtrl.dispose();
  }

  Color _rankColor(int index) {
    if (index == 0) return RankingTokens.rankGold;
    if (index == 1) return RankingTokens.rankSilver;
    if (index == 2) return RankingTokens.rankBronze;
    return const Color(0xFF9CA3AF); // neutral gray instead of purple
  }
}

class _SubjectGroup {
  final String subject;
  final List<Teacher> teachers;

  const _SubjectGroup(this.subject, this.teachers);

  int get ratingCount =>
      teachers.fold<int>(0, (sum, teacher) => sum + teacher.ratingCount);

  double get averageStar {
    if (teachers.isEmpty) return 0;
    if (ratingCount == 0) {
      final sum = teachers.fold<double>(
        0,
        (value, teacher) => value + teacher.averageStar,
      );
      return sum / teachers.length;
    }
    final total = teachers.fold<double>(
      0,
      (value, teacher) => value + teacher.averageStar * teacher.ratingCount,
    );
    return total / ratingCount;
  }
}
