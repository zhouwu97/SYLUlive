import 'package:flutter/material.dart';

import '../models/teacher.dart';
import '../widgets/glass_container.dart';
import 'teacher_detail_screen.dart';

class SubjectRankingDetailScreen extends StatelessWidget {
  final String subjectName;
  final List<Teacher> teachers;

  const SubjectRankingDetailScreen({
    super.key,
    required this.subjectName,
    required this.teachers,
  });

  double get _weightedAverage {
    var weighted = 0.0;
    var total = 0;
    for (final teacher in teachers) {
      weighted += teacher.averageStar * teacher.ratingCount;
      total += teacher.ratingCount;
    }
    if (total == 0) {
      if (teachers.isEmpty) return 0;
      final sum = teachers.fold<double>(
          0, (value, teacher) => value + teacher.averageStar);
      return sum / teachers.length;
    }
    return weighted / total;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sorted = [...teachers]..sort((a, b) {
        final ratingCompare = b.averageStar.compareTo(a.averageStar);
        if (ratingCompare != 0) return ratingCompare;
        final countCompare = b.ratingCount.compareTo(a.ratingCount);
        if (countCompare != 0) return countCompare;
        return a.name.compareTo(b.name);
      });

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(subjectName),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          GlassContainer(
            padding: const EdgeInsets.all(20),
            borderRadius: 24,
            blur: 14,
            opacity: 0.18,
            backgroundColor:
                isDark ? const Color(0xA31A2040) : const Color(0xCCE8ECFF),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: const Color(0xFF6D5EF9).withValues(alpha: 0.14),
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
                            subjectName,
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '按教师评分排序，点击可查看详情与评价',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? Colors.white60 : Colors.black54,
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
              backgroundColor:
                  isDark ? const Color(0x99171B24) : const Color(0xCCFFFFFF),
              borderColor: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.white.withValues(alpha: 0.72),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TeacherDetailScreen(
                    teacherId: teacher.id,
                    teacherName: teacher.name,
                  ),
                ),
              ),
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
                              color: isDark ? Colors.white : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${teacher.averageStar.toStringAsFixed(1)} 分 · ${teacher.ratingCount} 条评价',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark ? Colors.white60 : Colors.black54,
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
    if (index == 2) return const Color(0xFF10B981);
    return const Color(0xFF8B5CF6);
  }
}
