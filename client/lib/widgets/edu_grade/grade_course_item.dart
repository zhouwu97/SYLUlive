import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';

/// Compact row for a single course grade.
/// Uses a thin Divider separator — NO Card borders.
class GradeCourseItem extends StatelessWidget {
  final EduGrade grade;

  const GradeCourseItem({super.key, required this.grade});

  /// Color for the displayed grade text based on score.
  static Color gradeColor(
      String displayGrade, bool? isPassed, BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (isPassed == false) return Colors.red;

    // Text grades
    final t = displayGrade.trim();
    if (t == '优秀') return Colors.green;
    if (t == '良好') return Colors.blue;
    if (t == '中等' || t == '合格' || t == '及格') {
      return isDark ? Colors.white70 : Colors.black87;
    }
    if (t == '不及格' || t == '不合格') return Colors.red;

    // Numeric grades
    final num = double.tryParse(t);
    if (num != null) {
      if (num >= 90) return Colors.green;
      if (num >= 80) return Colors.blue;
      if (num >= 60) return isDark ? Colors.white70 : Colors.black87;
      return Colors.red;
    }

    // Unknown
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = gradeColor(grade.displayGrade, grade.isPassed, context);
    final gpaText =
        grade.gpa != null ? ' · 绩点 ${grade.gpa!.toStringAsFixed(2)}' : '';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          // Left: course info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  grade.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '${grade.credits.toStringAsFixed(1)} 学分$gpaText',
                      style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                    ),
                    if (grade.isDegree) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: (isDark ? Colors.blue[900] : Colors.blue[50])!,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '学位课',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? Colors.blue[200] : Colors.blue[700],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Right: grade score
          Text(
            grade.displayGrade,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
