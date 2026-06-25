import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';

/// Compact overview bar showing semester stats.
/// Height ~72–88, no giant GPA number, no GPA color coding.
/// Always operates on the FULL grade list (never filtered).
class GradeSummaryCard extends StatelessWidget {
  final List<EduGrade> grades;

  const GradeSummaryCard({super.key, required this.grades});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final gpa = EduGrade.computeWeightedGpa(grades);

    final courseCount = grades.length;
    final totalCredits = grades.fold<double>(0, (sum, g) => sum + g.credits);
    final passedCount = grades.where((g) => g.isPassed == true).length;
    final gpaText = gpa != null ? gpa.toStringAsFixed(2) : '--';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Text(
            '本学期概览',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          // Compact stat row
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey[850] : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              children: [
                _Stat(label: '课程', value: '$courseCount'),
                _divider(context),
                _Stat(label: '学分', value: totalCredits.toStringAsFixed(1)),
                _divider(context),
                _Stat(label: '已通过', value: '$passedCount'),
                _divider(context),
                _Stat(label: 'GPA', value: gpaText),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider(BuildContext context) {
    return Container(
      width: 1,
      height: 32,
      color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;

  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
}
