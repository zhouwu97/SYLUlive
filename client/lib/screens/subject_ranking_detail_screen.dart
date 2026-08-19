import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/teacher.dart';
import '../providers/teacher_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/rating_detail/ranking_tokens.dart';
import 'teacher_detail_screen.dart';

class SubjectRankingDetailScreen extends StatefulWidget {
  final String subjectName;
  final List<Teacher> teachers;

  const SubjectRankingDetailScreen({
    super.key,
    required this.subjectName,
    required this.teachers,
  });

  @override
  State<SubjectRankingDetailScreen> createState() =>
      _SubjectRankingDetailScreenState();
}

class _SubjectRankingDetailScreenState
    extends State<SubjectRankingDetailScreen> {
  late List<Teacher> _teachers;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _teachers = List<Teacher>.from(widget.teachers);
  }

  double get _weightedAverage {
    var weighted = 0.0;
    var total = 0;
    for (final teacher in _teachers) {
      weighted += teacher.averageStar * teacher.ratingCount;
      total += teacher.ratingCount;
    }
    if (total == 0) {
      if (_teachers.isEmpty) return 0;
      final sum = _teachers.fold<double>(
        0,
        (value, teacher) => value + teacher.averageStar,
      );
      return sum / _teachers.length;
    }
    return weighted / total;
  }

  Future<void> _openTeacherDetail(Teacher teacher) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => TeacherDetailScreen(
          teacherId: teacher.id,
          teacherName: teacher.name,
        ),
      ),
    );
    if (changed != true || !mounted) return;

    _changed = true;
    await context.read<TeacherProvider>().loadTeachers();
    if (!mounted) return;

    final refreshed = context
        .read<TeacherProvider>()
        .teachers
        .where((item) => item.course.trim() == widget.subjectName.trim())
        .toList()
      ..sort((a, b) {
        final ratingCompare = b.averageStar.compareTo(a.averageStar);
        if (ratingCompare != 0) return ratingCompare;
        final countCompare = b.ratingCount.compareTo(a.ratingCount);
        if (countCompare != 0) return countCompare;
        return a.name.compareTo(b.name);
      });

    if (mounted)
      setState(() {
        _teachers = refreshed;
      });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final accent = RankingTokens.teacherAccent(isDark);
    final sorted = [..._teachers]..sort((a, b) {
        final ratingCompare = b.averageStar.compareTo(a.averageStar);
        if (ratingCompare != 0) return ratingCompare;
        final countCompare = b.ratingCount.compareTo(a.ratingCount);
        if (countCompare != 0) return countCompare;
        return a.name.compareTo(b.name);
      });

    return PopScope(
      canPop: themeProvider.predictiveBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _changed);
      },
      child: Scaffold(
        backgroundColor: RankingTokens.pageBg(isDark),
        extendBodyBehindAppBar: false,
        appBar: AppBar(
          title: Text(
            widget.subjectName,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          backgroundColor: RankingTokens.pageBg(isDark),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
          ),
          titleTextStyle: TextStyle(
            color: RankingTokens.titleColor(isDark),
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
          iconTheme: IconThemeData(color: RankingTokens.titleColor(isDark)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _changed),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // Header card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: RankingTokens.cardDecoration(isDark),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: RankingTokens.teacherAccentSoft(isDark),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          Icons.auto_stories_outlined,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.subjectName,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: RankingTokens.titleColor(isDark),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '按教师评分排序，点击可查看详情与评价',
                              style: TextStyle(
                                fontSize: 12,
                                color: RankingTokens.subColor(isDark),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      _buildMetric(
                        isDark,
                        '教师数',
                        '${sorted.length}',
                        Icons.groups_2_outlined,
                        accent,
                      ),
                      const SizedBox(width: 10),
                      _buildMetric(
                        isDark,
                        '学科均分',
                        _weightedAverage.toStringAsFixed(1),
                        Icons.star_rounded,
                        accent,
                      ),
                      const SizedBox(width: 10),
                      _buildMetric(
                        isDark,
                        '总评价数',
                        '${sorted.fold<int>(0, (sum, t) => sum + t.ratingCount)}',
                        Icons.rate_review_outlined,
                        accent,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            ...sorted.asMap().entries.map(
              (entry) {
                final index = entry.key;
                final teacher = entry.value;
                final rankColor = _rankColor(index);
                return Padding(
                  padding: EdgeInsets.only(bottom: RankingTokens.cardGap),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius:
                          BorderRadius.circular(RankingTokens.cardRadius),
                      onTap: () => _openTeacherDetail(teacher),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: RankingTokens.cardDecoration(isDark),
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: rankColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '#${index + 1}',
                                style: TextStyle(
                                  color: rankColor,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    teacher.name,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: RankingTokens.titleColor(isDark),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${teacher.averageStar.toStringAsFixed(1)} 分 · ${teacher.ratingCount} 条评价',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: RankingTokens.subColor(isDark),
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetric(
    bool isDark,
    String label,
    String value,
    IconData icon,
    Color accent,
  ) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.04)
              : accent.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 15, color: accent),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    color: RankingTokens.subColor(isDark),
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: RankingTokens.titleColor(isDark),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _rankColor(int index) {
    if (index == 0) return RankingTokens.rankGold;
    if (index == 1) return RankingTokens.rankSilver;
    if (index == 2) return RankingTokens.rankBronze;
    return const Color(0xFF9CA3AF);
  }
}
