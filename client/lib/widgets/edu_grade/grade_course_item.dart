import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';

/// Compact row for a single course grade.
/// Uses a thin Divider separator — NO Card borders.
class GradeCourseItem extends StatelessWidget {
  final EduGrade grade;
  final VoidCallback? onTap;

  const GradeCourseItem({super.key, required this.grade, this.onTap});

  /// Restrained color for the displayed grade text.
  /// Only fail → red, 优秀 → green, everything else → body color.
  static Color gradeColor(
      String displayGrade, bool? isPassed, BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final t = displayGrade.trim();

    if (isPassed == false) return Colors.red;
    if (t == '优秀') return Colors.green;

    return isDark ? Colors.white : Colors.black87;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = gradeColor(grade.displayGrade, grade.isPassed, context);
    final gpaText =
        grade.gpa != null ? ' · 绩点 ${grade.gpa!.toStringAsFixed(2)}' : '';

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                    if (grade.isDegree) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
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
              fontSize: 23,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: Colors.grey[400]),
          ],
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        child: row,
      );
    }

    return row;
  }
}
