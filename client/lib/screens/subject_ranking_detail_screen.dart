import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/teacher.dart';
import '../providers/teacher_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/glass_container.dart';
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
          0, (value, teacher) => value + teacher.averageStar);
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

    setState(() {
      _teachers = refreshed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeProvider = context.watch<ThemeProvider>();
    final sorted = [..._teachers]..sort((a, b) {
        final ratingCompare = b.averageStar.compareTo(a.averageStar);
        if (ratingCompare != 0) return ratingCompare;
        final countCompare = b.ratingCount.compareTo(a.ratingCount);
        if (countCompare != 0) return countCompare;
        return a.name.compareTo(b.name);
      });

    return PopScope(
      canPop: !themeProvider.predictiveBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.pop(context, _changed);
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: false, // 关闭延伸，防止 AppBar 与 Body 重叠
        appBar: AppBar(
          title: Text(widget.subjectName),
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true, // 标题居中显示
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
          ),
          titleTextStyle: TextStyle(
            color: isDark ? Colors.white : Colors.black87,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(
            color: isDark ? Colors.white : Colors.black87,
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context, _changed),
          ),
        ),
        body: Stack(
          children: [
            Positioned.fill(child: _buildBackground(themeProvider, isDark)),
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), // 顶部边距设为 0
              children: [
                GlassContainer(
                  padding: const EdgeInsets.all(20),
                  borderRadius: 24,
                  blur: 14,
                  opacity: 0.18,
                  backgroundColor: isDark
                      ? const Color(0xA31A2040)
                      : const Color(0xCCE8ECFF),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: const Color(0xFF6D5EF9)
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(
                              Icons.auto_stories_outlined,
                              color: Color(0xFF6D5EF9),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.subjectName,
                                  style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    color:
                                        isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '按教师评分排序，点击可查看详情与评价',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: isDark
                                        ? Colors.white60
                                        : Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _buildMetric(
                            isDark,
                            '教师数',
                            '${sorted.length}',
                            Icons.groups_2_outlined,
                          ),
                          _buildMetric(
                            isDark,
                            '学科均分',
                            _weightedAverage.toStringAsFixed(1),
                            Icons.star_rounded,
                          ),
                          _buildMetric(
                            isDark,
                            '总评价数',
                            '${sorted.fold<int>(0, (sum, t) => sum + t.ratingCount)}',
                            Icons.rate_review_outlined,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                ...sorted.asMap().entries.map((entry) {
                  final index = entry.key;
                  final teacher = entry.value;
                  final accent = _rankColor(index);
                  return GlassContainer(
                    margin: const EdgeInsets.only(bottom: 12),
                    borderRadius: 20,
                    blur: 12,
                    opacity: 0.18,
                    backgroundColor: isDark
                        ? const Color(0x99171B24)
                        : const Color(0xCCFFFFFF),
                    borderColor: isDark
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.72),
                    onTap: () => _openTeacherDetail(teacher),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              '#${index + 1}',
                              style: TextStyle(
                                color: accent,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  teacher.name,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color:
                                        isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${teacher.averageStar.toStringAsFixed(1)} 分 · ${teacher.ratingCount} 条评价',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: isDark
                                        ? Colors.white60
                                        : Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackground(ThemeProvider themeProvider, bool isDark) {
    if (themeProvider.hasBackground && themeProvider.backgroundImage != null) {
      final bgPath = themeProvider.backgroundImage!;
      final isAsset = !bgPath.startsWith('http') && !bgPath.startsWith('/');
      return Stack(
        fit: StackFit.expand,
        children: [
          isAsset
              ? Image.asset(
                  'assets/images/$bgPath',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _buildDefaultBackground(isDark),
                )
              : bgPath.startsWith('/')
                  ? Image.file(
                      File(bgPath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildDefaultBackground(isDark),
                    )
                  : Image.network(
                      bgPath,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _buildDefaultBackground(isDark),
                    ),
          Container(
            color: isDark
                ? Colors.black.withValues(alpha: 0.35)
                : Colors.white.withValues(alpha: 0.25),
          ),
        ],
      );
    }
    return _buildDefaultBackground(isDark);
  }

  Widget _buildDefaultBackground(bool isDark) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: ResizeImage(
            const AssetImage('assets/images/morenbeijing.jpeg'),
            width: 1080,
          ),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: isDark ? const Color(0xFF0F131A) : const Color(0xFFF5F7FB),
          ),
        ),
        Container(
          color: isDark
              ? Colors.black.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.25),
        ),
      ],
    );
  }

  Widget _buildMetric(
    bool isDark,
    String label,
    String value,
    IconData icon,
  ) {
    return SizedBox(
      child: GlassContainer(
        width: 120,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        borderRadius: 16,
        blur: 8,
        opacity: 0.14,
        backgroundColor: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.white.withValues(alpha: 0.72),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: const Color(0xFF6D5EF9)),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white60 : Colors.black54,
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : Colors.black87,
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
    if (index == 0) return const Color(0xFFF59E0B);
    if (index == 1) return const Color(0xFF6366F1);
    if (index == 2) return const Color(0xFF14B8A6);
    return const Color(0xFF64748B);
  }
}
