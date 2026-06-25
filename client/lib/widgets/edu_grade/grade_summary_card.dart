import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';

/// Summary card showing computed GPA and stats for a list of grades.
/// Always operates on the FULL grade list (never filtered).
class GradeSummaryCard extends StatelessWidget {
  final List<EduGrade> grades;

  const GradeSummaryCard({super.key, required this.grades});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gpa = EduGrade.computeWeightedGpa(grades);

    final courseCount = grades.length;
    final totalCredits = grades.fold<double>(
      0,
      (sum, g) => sum + g.credits,
    );
    final degreeCount = grades.where((g) => g.isDegree).length;
    final passedCount = grades.where((g) => g.isPassed == true).length;

    // Count courses that contribute to GPA
    final gpaCourseCount =
        grades.where((g) => g.gpa != null && g.credits > 0).length;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey[850] : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          children: [
            // GPA
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '本学期平均绩点',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (gpaCourseCount < grades.length || gpaCourseCount == 0)
                  Tooltip(
                    message: '部分课程（如合格/优秀制）不参与绩点计算',
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.help_outline,
                        size: 14,
                        color: Colors.grey[400],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              gpa != null ? gpa.toStringAsFixed(2) : '--',
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w700,
                color: _gpaColor(gpa, isDark),
              ),
            ),
            Text(
              '按课程学分加权计算',
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
            const SizedBox(height: 16),
            // Stats grid
            Row(
              children: [
                _StatItem(label: '课程', value: '$courseCount'),
                _StatItem(label: '学分', value: totalCredits.toStringAsFixed(1)),
                _StatItem(label: '学位课', value: '$degreeCount'),
                _StatItem(label: '已通过', value: '$passedCount'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _gpaColor(double? gpa, bool isDark) {
    if (gpa == null) return Colors.grey;
    if (gpa >= 3.5) return Colors.green;
    if (gpa >= 2.5) return Colors.blue;
    if (gpa >= 2.0) return isDark ? Colors.white : Colors.black87;
    return Colors.orange;
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;

  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
}
