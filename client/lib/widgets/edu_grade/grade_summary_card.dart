import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';
import '../../utils/edu_semester_utils.dart';

/// Unified overview card — semester info + stats in 2 compact rows.
/// No "上次更新", no GPA, no tap.
/// Always operates on the FULL grade list (never filtered).
class GradeSummaryCard extends StatelessWidget {
  final String selectedYear;
  final int selectedSemester;
  final List<EduGrade> grades;

  const GradeSummaryCard({
    super.key,
    required this.selectedYear,
    required this.selectedSemester,
    required this.grades,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final courseCount = grades.length;
    final passedCount = grades.where((g) => g.isPassed == true).length;
    final degreeCount = grades.where((g) => g.isDegree).length;
    final totalCredits = grades.fold<double>(0, (sum, g) => sum + g.credits);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: isDark ? 0.2 : 0.35),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          children: [
            // Row 1: calendar + semester label | course count
            Row(
              children: [
                Icon(
                  Icons.calendar_month_outlined,
                  size: 19,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    EduSemester.fullLabel(selectedYear, selectedSemester),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                Text(
                  '$courseCount 门课程',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Row 2: three equal stats with dividers
            Row(
              children: [
                Expanded(
                  child: _metric(context, '本学期及格', '$passedCount'),
                ),
                _divider(context),
                Expanded(
                  child: _metric(context, '学位课', '$degreeCount'),
                ),
                _divider(context),
                Expanded(
                  child: _metric(
                    context,
                    '总学分',
                    totalCredits.toStringAsFixed(1),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context)
                .colorScheme
                .onPrimaryContainer
                .withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _divider(BuildContext context) {
    return Container(
      width: 1,
      height: 28,
      color: Theme.of(context)
          .colorScheme
          .onPrimaryContainer
          .withValues(alpha: 0.2),
    );
  }
}
