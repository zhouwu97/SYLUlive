import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../config/admin_feature_flags.dart';
import '../models/teacher.dart';
import '../providers/major_provider.dart';
import '../providers/teacher_provider.dart';
import '../utils/responsive_util.dart';
import '../widgets/rating_detail/ranking_tokens.dart';
import 'major_detail_screen.dart';
import 'subject_ranking_detail_screen.dart';
import 'package:shenliyuan/platform/contracts/preferences_store.dart';


class CampusRankingScreen extends StatefulWidget {
  const CampusRankingScreen({super.key});

  @override
  State<CampusRankingScreen> createState() => _CampusRankingScreenState();
}

class _CampusRankingScreenState extends State<CampusRankingScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  final _searchCtrl = TextEditingController();
  bool _showDisclaimer = false;

  @override
  void initState() {
    super.initState();
    _checkDisclaimer();
    _tabCtrl = TabController(length: 2, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAll());
  }

  Future<void> _checkDisclaimer() async {
    final prefs = await AppPreferencesStore.getInstance();
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
    ]);
  }

  String? get _currentQuery {
    final query = _searchCtrl.text.trim();
    return query.isEmpty ? null : query;
  }

  // ── per-tab accent helpers ─────────────────────────────────────────

  Color _tabAccent(bool isDark) => switch (_tabCtrl.index) {
        0 => RankingTokens.teacherAccent(isDark),
        _ => RankingTokens.majorAccent(isDark),
      };

  Color _tabAccentSoft(bool isDark) => switch (_tabCtrl.index) {
        0 => RankingTokens.teacherAccentSoft(isDark),
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
              if (_tabCtrl.index == 0 && _showDisclaimer)
                _buildDisclaimer(isDark),
              _buildSearchBar(isDark),
              _buildSegmentedControl(isDark),
              Expanded(
                child: _tabCtrl.index == 0
                    ? _buildSubjectList(isDark)
                    : _buildMajorList(isDark),
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
            Expanded(child: _buildSegmentItem(0, '学科榜', isDark)),
            Expanded(child: _buildSegmentItem(1, '专业榜', isDark)),
          ],
        ),
      ),
    );
  }

  Widget _buildSegmentItem(int index, String label, bool isDark) {
    final isSelected = _tabCtrl.index == index;
    final accent = switch (index) {
      0 => RankingTokens.teacherAccent(isDark),
      _ => RankingTokens.majorAccent(isDark),
    };
    final accentSoft = switch (index) {
      0 => isDark
          ? const Color(0xFF7ED6C5).withValues(alpha: 0.12)
          : const Color(0xFFE8F5E9),
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
        0 => '添加授课教师',
        _ => '添加专业',
      };

  Widget _buildFAB(bool isDark, Color accent) {
    if (!AdminFeatureFlags.reviewEnabled) {
      return const SizedBox.shrink();
    }
    final bottomSafe = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSafe > 0 ? bottomSafe : 0),
      child: FloatingActionButton.extended(
        heroTag: 'campus_ranking_fab',
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
                '学科榜按课程聚合。添加授课教师时请选择标准课程名，例如"数据结构""高等数学A1"，避免同一课程被拆散。',
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
                final prefs = await AppPreferencesStore.getInstance();
                await prefs.setBool('has_shown_teacher_disclaimer', true);
              },
              child: Icon(Icons.close,
                  size: 16, color: RankingTokens.subColor(isDark)),
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
                  ? '搜索学科或教师...'
                  : '搜索专业...',
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
            // 两个 Tab 均为本地即时过滤：学科榜在 _buildSubjectGroups 中过滤，
            // 专业榜在 _buildMajorList 中过滤。这里只触发重建，不发网络请求，
            // 避免专业榜搜索误请求教师接口、以及无 debounce 的高频请求。
            onChanged: (_) => setState(() {}),
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

  // ── Add dialog (teacher / major) ───────────────────────────────────

  Future<void> _showAddDialog() async {
    if (_tabCtrl.index == 0) {
      await _showAddTeacherSheet();
    } else {
      await _showAddMajorSheet();
    }
  }

  // ── Add-teacher / Add-major bottom sheets ──────────────────────────

  Widget _sheetDragHandle(bool isDark) => Center(
        child: Container(
          width: 42,
          height: 4,
          decoration: BoxDecoration(
            color: RankingTokens.borderColor(isDark),
            borderRadius: BorderRadius.circular(99),
          ),
        ),
      );

  Widget _addSheetHeader({
    required bool isDark,
    required Color accent,
    required Color accentSoft,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: accentSoft,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: RankingTokens.titleColor(isDark),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: RankingTokens.subColor(isDark),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  InputDecoration _addSheetFieldDecoration({
    required bool isDark,
    required Color accent,
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: RankingTokens.subColor(isDark)),
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: RankingTokens.pageBg(isDark),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: RankingTokens.borderColor(isDark)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: RankingTokens.borderColor(isDark)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: accent, width: 1.4),
      ),
    );
  }

  Widget _addSheetStatusChip(
      bool isDark, Color? color, String text, IconData icon) {
    final c =
        color ?? (isDark ? Colors.grey.shade400 : const Color(0xFF7A8087));
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: c,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _addSheetButtons({
    required bool isDark,
    required Color accent,
    required bool submitting,
    required bool canSubmit,
    required VoidCallback onCancel,
    required Future<void> Function() onSubmit,
  }) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: submitting ? null : onCancel,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              side: BorderSide(color: RankingTokens.borderColor(isDark)),
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
            onPressed: (submitting || !canSubmit)
                ? null
                : () async {
                    await onSubmit();
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
    );
  }

  Future<void> _showAddTeacherSheet() async {
    final nameCtrl = TextEditingController();
    final courseCtrl = TextEditingController();
    var submitting = false;
    String? selectedCourse;
    bool createNew = false;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = RankingTokens.teacherAccent(isDark);
    final accentSoft = RankingTokens.teacherAccentSoft(isDark);
    final warningColor =
        isDark ? const Color(0xFFF4B860) : const Color(0xFFC47C14);

    await context.read<TeacherProvider>().loadAllTeachersForSuggestions();
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModalState) {
            final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
            final teachers = context.read<TeacherProvider>().allTeachers;
            final suggestions =
                _buildCourseSuggestions(courseCtrl.text, teachers);
            final trimmed = courseCtrl.text.trim();
            final hasSimilar = suggestions.isNotEmpty;
            final courseReady =
                selectedCourse != null || (createNew && trimmed.isNotEmpty);
            final nameInput = nameCtrl.text.trim();
            final determinedCourse =
                selectedCourse ?? (createNew ? trimmed : '');
            final duplicate = nameInput.isNotEmpty &&
                determinedCourse.isNotEmpty &&
                teachers.any((t) =>
                    t.course.trim() == determinedCourse &&
                    t.name.trim() == nameInput);

            return Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
                ),
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
                      _sheetDragHandle(isDark),
                      const SizedBox(height: 16),
                      _addSheetHeader(
                        isDark: isDark,
                        accent: accent,
                        accentSoft: accentSoft,
                        icon: Icons.school_rounded,
                        title: '添加授课教师',
                        subtitle: '同名同课程不可重复；不同课程可分别添加',
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: nameCtrl,
                        textInputAction: TextInputAction.next,
                        onChanged: (_) => setModalState(() {}),
                        decoration: _addSheetFieldDecoration(
                          isDark: isDark,
                          accent: accent,
                          hint: '教师姓名',
                          icon: Icons.person_rounded,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: courseCtrl,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) {
                          selectedCourse = null;
                          createNew = false;
                          setModalState(() {});
                        },
                        decoration: _addSheetFieldDecoration(
                          isDark: isDark,
                          accent: accent,
                          hint: '搜索课程，例如 高等数学A2',
                          icon: Icons.book_rounded,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (duplicate)
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                          decoration: BoxDecoration(
                            color: warningColor.withValues(
                                alpha: isDark ? 0.14 : 0.10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: warningColor.withValues(
                                  alpha: isDark ? 0.30 : 0.22),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline_rounded,
                                  size: 18, color: warningColor),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '「$nameInput · $determinedCourse」已存在，不能再重复添加',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: warningColor,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  final courseTeachers = teachers
                                      .where((t) =>
                                          t.course.trim() == determinedCourse)
                                      .toList();
                                  Navigator.pop(sheetContext);
                                  if (mounted) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            SubjectRankingDetailScreen(
                                          subjectName: determinedCourse,
                                          teachers: courseTeachers,
                                        ),
                                      ),
                                    );
                                  }
                                },
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(58, 34),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10),
                                  foregroundColor: warningColor,
                                  textStyle: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                child: const Text('查看评价'),
                              ),
                            ],
                          ),
                        )
                      else if (selectedCourse != null)
                        _addSheetStatusChip(
                          isDark,
                          accent,
                          '将添加到「$selectedCourse」',
                          Icons.check_circle_rounded,
                        )
                      else if (hasSimilar && !createNew)
                        _addSheetStatusChip(
                          isDark,
                          warningColor,
                          '请选择已有课程，避免重复创建',
                          Icons.warning_amber_rounded,
                        )
                      else if (trimmed.isEmpty)
                        _addSheetStatusChip(
                          isDark,
                          null,
                          '输入课程名以搜索已有学科',
                          Icons.info_outline_rounded,
                        )
                      else if (!hasSimilar && !createNew)
                        _addSheetStatusChip(
                          isDark,
                          null,
                          '没有匹配，可点下方创建新课程',
                          Icons.info_outline_rounded,
                        )
                      else if (createNew)
                        _addSheetStatusChip(
                          isDark,
                          accent,
                          '将创建新课程「$trimmed」',
                          Icons.check_circle_rounded,
                        ),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final s in suggestions)
                                InkWell(
                                  onTap: () {
                                    selectedCourse = s.name;
                                    createNew = false;
                                    courseCtrl.text = s.name;
                                    courseCtrl.selection =
                                        TextSelection.collapsed(
                                      offset: s.name.length,
                                    );
                                    setModalState(() {});
                                  },
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    height: 52,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    margin: const EdgeInsets.only(bottom: 6),
                                    decoration: BoxDecoration(
                                      color: selectedCourse == s.name
                                          ? accentSoft
                                          : RankingTokens.pageBg(isDark),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: selectedCourse == s.name
                                            ? accent
                                            : RankingTokens.borderColor(isDark),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            color: accentSoft,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Icon(Icons.book_rounded,
                                              size: 18, color: accent),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                s.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color:
                                                      RankingTokens.titleColor(
                                                          isDark),
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${s.teacherCount} 位教师 · ${s.ratingCount} 条评价',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: RankingTokens.subColor(
                                                      isDark),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (selectedCourse == s.name)
                                          Icon(Icons.check_circle_rounded,
                                              size: 20, color: accent),
                                      ],
                                    ),
                                  ),
                                ),
                              if (suggestions.isEmpty &&
                                  trimmed.isNotEmpty &&
                                  !createNew)
                                InkWell(
                                  onTap: () {
                                    createNew = true;
                                    selectedCourse = null;
                                    setModalState(() {});
                                  },
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    height: 52,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: accent.withValues(alpha: 0.5),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(Icons.add_circle_outline_rounded,
                                            size: 20, color: accent),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            '创建新课程：$trimmed',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: accent,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _addSheetButtons(
                        isDark: isDark,
                        accent: accent,
                        submitting: submitting,
                        canSubmit:
                            nameInput.isNotEmpty && courseReady && !duplicate,
                        onCancel: () => Navigator.pop(sheetContext),
                        onSubmit: () async {
                          final name = nameCtrl.text.trim();
                          final course = selectedCourse ??
                              (createNew ? courseCtrl.text.trim() : '');
                          if (name.isEmpty || course.isEmpty) return;
                          setModalState(() => submitting = true);
                          final ok = await context
                              .read<TeacherProvider>()
                              .addTeacher(name, course);
                          if (!mounted || !sheetContext.mounted) return;
                          setModalState(() => submitting = false);
                          if (ok) {
                            Navigator.pop(sheetContext);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('添加成功')),
                              );
                              await context
                                  .read<TeacherProvider>()
                                  .loadTeachers(query: _currentQuery);
                            }
                          } else {
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              const SnackBar(
                                content: Text('添加失败，请稍后重试'),
                              ),
                            );
                          }
                        },
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
    courseCtrl.dispose();
  }

  Future<void> _showAddMajorSheet() async {
    final nameCtrl = TextEditingController();
    var level = '本科';
    var submitting = false;
    String? selectedMajor;
    bool createNew = false;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = RankingTokens.majorAccent(isDark);
    final accentSoft = RankingTokens.majorAccentSoft(isDark);
    final warningColor =
        isDark ? const Color(0xFFF4B860) : const Color(0xFFC47C14);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModalState) {
            final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;
            final majors = context.read<MajorProvider>().majors;
            final suggestions = _buildMajorSuggestions(nameCtrl.text, majors);
            final trimmed = nameCtrl.text.trim();
            final hasSimilar = suggestions.isNotEmpty;
            final nameReady =
                selectedMajor != null || (createNew && trimmed.isNotEmpty);

            return Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
                ),
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
                      _sheetDragHandle(isDark),
                      const SizedBox(height: 16),
                      _addSheetHeader(
                        isDark: isDark,
                        accent: accent,
                        accentSoft: accentSoft,
                        icon: Icons.workspace_premium_rounded,
                        title: '添加专业',
                        subtitle: '搜索已有专业并选择标准名，避免重复',
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: nameCtrl,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) {
                          selectedMajor = null;
                          createNew = false;
                          setModalState(() {});
                        },
                        decoration: _addSheetFieldDecoration(
                          isDark: isDark,
                          accent: accent,
                          hint: '搜索专业，例如 机械',
                          icon: Icons.school_rounded,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: RankingTokens.pageBg(isDark),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: RankingTokens.borderColor(isDark),
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: level,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: '本科', child: Text('本科')),
                              DropdownMenuItem(
                                  value: '研究生', child: Text('研究生')),
                            ],
                            onChanged: (v) {
                              if (v != null) {
                                level = v;
                                setModalState(() {});
                              }
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (selectedMajor != null)
                        _addSheetStatusChip(
                          isDark,
                          accent,
                          '将添加到「$selectedMajor」',
                          Icons.check_circle_rounded,
                        )
                      else if (hasSimilar && !createNew)
                        _addSheetStatusChip(
                          isDark,
                          warningColor,
                          '请选择已有专业，避免重复创建',
                          Icons.warning_amber_rounded,
                        )
                      else if (trimmed.isEmpty)
                        _addSheetStatusChip(
                          isDark,
                          null,
                          '输入专业名以搜索',
                          Icons.info_outline_rounded,
                        )
                      else if (!hasSimilar && !createNew)
                        _addSheetStatusChip(
                          isDark,
                          null,
                          '没有匹配，可点下方创建新专业',
                          Icons.info_outline_rounded,
                        )
                      else if (createNew)
                        _addSheetStatusChip(
                          isDark,
                          accent,
                          '将创建新专业「$trimmed」',
                          Icons.check_circle_rounded,
                        ),
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final s in suggestions)
                                InkWell(
                                  onTap: () {
                                    selectedMajor = s.name;
                                    createNew = false;
                                    nameCtrl.text = s.name;
                                    nameCtrl.selection =
                                        TextSelection.collapsed(
                                      offset: s.name.length,
                                    );
                                    setModalState(() {});
                                  },
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    height: 52,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    margin: const EdgeInsets.only(bottom: 6),
                                    decoration: BoxDecoration(
                                      color: selectedMajor == s.name
                                          ? accentSoft
                                          : RankingTokens.pageBg(isDark),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: selectedMajor == s.name
                                            ? accent
                                            : RankingTokens.borderColor(isDark),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            color: accentSoft,
                                            borderRadius:
                                                BorderRadius.circular(10),
                                          ),
                                          child: Icon(
                                              Icons.workspace_premium_rounded,
                                              size: 18,
                                              color: accent),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                s.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color:
                                                      RankingTokens.titleColor(
                                                          isDark),
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${s.level} · ${s.ratingCount} 条评价',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: RankingTokens.subColor(
                                                      isDark),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (selectedMajor == s.name)
                                          Icon(Icons.check_circle_rounded,
                                              size: 20, color: accent),
                                      ],
                                    ),
                                  ),
                                ),
                              if (suggestions.isEmpty &&
                                  trimmed.isNotEmpty &&
                                  !createNew)
                                InkWell(
                                  onTap: () {
                                    createNew = true;
                                    selectedMajor = null;
                                    setModalState(() {});
                                  },
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    height: 52,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: accent.withValues(alpha: 0.5),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(Icons.add_circle_outline_rounded,
                                            size: 20, color: accent),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            '创建新专业：$trimmed',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: accent,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _addSheetButtons(
                        isDark: isDark,
                        accent: accent,
                        submitting: submitting,
                        canSubmit: nameReady,
                        onCancel: () => Navigator.pop(sheetContext),
                        onSubmit: () async {
                          final name = selectedMajor ??
                              (createNew ? nameCtrl.text.trim() : '');
                          if (name.isEmpty) return;
                          setModalState(() => submitting = true);
                          final ok = await context
                              .read<MajorProvider>()
                              .addMajor(name, level);
                          if (!mounted || !sheetContext.mounted) return;
                          setModalState(() => submitting = false);
                          if (ok) {
                            Navigator.pop(sheetContext);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('添加成功')),
                              );
                              await context.read<MajorProvider>().loadMajors();
                            }
                          } else {
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              const SnackBar(
                                content: Text('添加失败，请稍后重试'),
                              ),
                            );
                          }
                        },
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

// ── Course / major name normalization & suggestion builders ─────────

const Map<String, String> _courseAliases = {
  '高数': '高等数学',
  '大英': '大学英语',
  '毛概': '毛泽东思想和中国特色社会主义理论体系概论',
  '马原': '马克思主义基本原理',
  '近代史': '中国近现代史纲要',
};

String _normalizeName(String input, [Map<String, String>? aliases]) {
  var r = input.trim();
  if (aliases != null) {
    for (final e in aliases.entries) {
      r = r.replaceAll(e.key, e.value);
    }
  }
  return r.toLowerCase().replaceAll(RegExp(r'\s+'), '');
}

class _CourseSuggestion {
  final String name;
  final int teacherCount;
  final int ratingCount;
  final int matchRank;
  const _CourseSuggestion(
      this.name, this.teacherCount, this.ratingCount, this.matchRank);
}

List<_CourseSuggestion> _buildCourseSuggestions(
    String query, List<Teacher> teachers) {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final nq = _normalizeName(q, _courseAliases);
  if (nq.isEmpty) return const [];
  final stats = <String, _CourseSuggestion>{};
  for (final t in teachers) {
    final key = t.course.trim();
    if (key.isEmpty) continue;
    final nc = _normalizeName(key, _courseAliases);
    int rank;
    if (nc == nq) {
      rank = 0;
    } else if (nc.contains(nq)) {
      rank = 1;
    } else if (nq.contains(nc) && nc.length >= 2) {
      rank = 2;
    } else {
      continue;
    }
    final existing = stats[key];
    if (existing == null) {
      stats[key] = _CourseSuggestion(key, 1, t.ratingCount, rank);
    } else {
      final newRank = existing.matchRank < rank ? existing.matchRank : rank;
      stats[key] = _CourseSuggestion(
        key,
        existing.teacherCount + 1,
        existing.ratingCount + t.ratingCount,
        newRank,
      );
    }
  }
  final list = stats.values.toList();
  list.sort((a, b) {
    final r = a.matchRank.compareTo(b.matchRank);
    if (r != 0) return r;
    return b.teacherCount.compareTo(a.teacherCount);
  });
  return list.take(8).toList();
}

class _MajorSuggestion {
  final String name;
  final String level;
  final int ratingCount;
  final int matchRank;
  const _MajorSuggestion(
      this.name, this.level, this.ratingCount, this.matchRank);
}

List<_MajorSuggestion> _buildMajorSuggestions(
    String query, List<MajorItem> majors) {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final nq = _normalizeName(q);
  if (nq.isEmpty) return const [];
  final result = <_MajorSuggestion>[];
  for (final m in majors) {
    final key = m.name.trim();
    if (key.isEmpty) continue;
    final nc = _normalizeName(key);
    int rank;
    if (nc == nq) {
      rank = 0;
    } else if (nc.contains(nq)) {
      rank = 1;
    } else if (nq.contains(nc) && nc.length >= 2) {
      rank = 2;
    } else {
      continue;
    }
    result.add(_MajorSuggestion(key, m.level, m.ratingCount, rank));
  }
  result.sort((a, b) {
    final r = a.matchRank.compareTo(b.matchRank);
    if (r != 0) return r;
    return b.ratingCount.compareTo(a.ratingCount);
  });
  return result.take(8).toList();
}
