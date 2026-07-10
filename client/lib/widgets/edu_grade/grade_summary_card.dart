import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';
import '../../utils/edu_semester_utils.dart';

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
    final termGpa = EduGrade.computeWeightedGpa(grades);
    final gpaText = termGpa?.toStringAsFixed(2) ?? '--';

    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF7A8087);
    final accentColor =
        isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          gradient: isDark
              ? null
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white,
                    Color(0xFFF1FBF7),
                  ],
                ),
          color: isDark ? const Color(0xFF1E2226) : null,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : const Color(0xFFE2EFEA),
          ),
          boxShadow: isDark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.035),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isDark
                    ? accentColor.withValues(alpha: 0.12)
                    : const Color(0xFFEAF6F3),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.calendar_month_outlined,
                size: 20,
                color: accentColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    EduSemester.fullLabel(selectedYear, selectedSemester),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$courseCount 门课程',
                    style: TextStyle(
                      fontSize: 13,
                      color: subColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '学期 GPA',
                  style: TextStyle(
                    fontSize: 12,
                    color: subColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  gpaText,
                  style: TextStyle(
                    fontSize: 28,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    color: accentColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
