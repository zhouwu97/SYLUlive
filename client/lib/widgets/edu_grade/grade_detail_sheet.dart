import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';

/// Bottom sheet showing course grade details.
/// Only displays data that is actually available — no `--` everywhere.
/// First version: name, displayGrade, credits, gpa, isDegree (from EduGrade).
class GradeDetailSheet extends StatelessWidget {
  final EduGrade grade;

  const GradeDetailSheet({super.key, required this.grade});

  static void show(BuildContext context, EduGrade grade) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => GradeDetailSheet(grade: grade),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Course name
          Text(
            grade.name,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),

          // Score (largest element)
          Center(
            child: Text(
              grade.displayGrade,
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.w700,
                color: _gradeColor(grade),
              ),
            ),
          ),
          const SizedBox(height: 4),

          // Tags row
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (grade.isDegree) _tag(context, '学位课', isDark),
                if (grade.isDegree) const SizedBox(width: 8),
                _tag(context, _examType, isDark),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 12),

          // Course info section
          _sectionHeader('课程信息'),
          const SizedBox(height: 8),
          _infoRow(context, '学分', grade.credits.toStringAsFixed(1)),
          if (grade.gpa != null)
            _infoRow(context, '绩点', grade.gpa!.toStringAsFixed(2)),
          _infoRow(context, '课程类型', grade.isDegree ? '学位课' : '非学位课'),

          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 12),

          // More data notice
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark ? Colors.grey[850] : Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: Colors.grey[500]),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '更多成绩构成（任课教师、平时/期末分等）暂未从教务系统获取',
                    style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _gradeColor(EduGrade g) {
    final t = g.displayGrade.trim();
    if (g.isPassed == false) return Colors.red;
    if (t == '优秀') return Colors.green;
    return Colors.black87;
  }

  String get _examType => '考试课'; // placeholder — real data pending

  Widget _tag(BuildContext context, String label, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 14, color: Colors.grey[600])),
          Text(value, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }
}
