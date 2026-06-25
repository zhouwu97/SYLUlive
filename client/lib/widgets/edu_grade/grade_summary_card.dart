import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';
import '../../utils/edu_semester_utils.dart';

/// Unified overview card merging semester info + stats.
/// No tap, no dropdown arrow. Semester switching moved to GradeManageSheet.
/// Always operates on the FULL grade list (never filtered).
class GradeSummaryCard extends StatelessWidget {
  final String selectedYear;
  final int selectedSemester;
  final DateTime? lastUpdatedAt;
  final List<EduGrade> grades;

  const GradeSummaryCard({
    super.key,
    required this.selectedYear,
    required this.selectedSemester,
    required this.lastUpdatedAt,
    required this.grades,
  });

  String _formatTime(DateTime? dt) {
    if (dt == null) return '暂未更新';
    final now = DateTime.now();
    final isToday =
        dt.year == now.year && dt.month == now.month && dt.day == now.day;
    if (isToday) {
      return '今天 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gpa = EduGrade.computeWeightedGpa(grades);

    final courseCount = grades.length;
    final totalCredits = grades.fold<double>(0, (sum, g) => sum + g.credits);
    final passedCount = grades.where((g) => g.isPassed == true).length;
    final degreeCount = grades.where((g) => g.isDegree).length;
    final gpaText = gpa != null ? gpa.toStringAsFixed(2) : '--';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: isDark ? 0.2 : 0.35),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: [
            // Top row: calendar icon + semester info
            Row(
              children: [
                Icon(
                  Icons.calendar_today_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        EduSemester.fullLabel(selectedYear, selectedSemester),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '上次更新：${_formatTime(lastUpdatedAt)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Main stats: courses count + total credits
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$courseCount',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '门课程',
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context)
                          .colorScheme
                          .onPrimaryContainer
                          .withValues(alpha: 0.8),
                    ),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        totalCredits.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color:
                              Theme.of(context).colorScheme.onPrimaryContainer,
                        ),
                      ),
                      Text(
                        '总学分',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer
                              .withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Bottom capsules: passed / degree / GPA
            Row(
              children: [
                _capsule(context, '本学期及格', '$passedCount'),
                const SizedBox(width: 10),
                _capsule(context, '学位课', '$degreeCount'),
                const SizedBox(width: 10),
                _capsule(context, 'GPA', gpaText),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _capsule(BuildContext context, String label, String value) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context)
                  .colorScheme
                  .onPrimaryContainer
                  .withValues(alpha: 0.7),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
