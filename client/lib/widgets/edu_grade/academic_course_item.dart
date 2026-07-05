import 'package:flutter/material.dart';
import '../../models/edu_academic_situation.dart';

class AcademicCourseItem extends StatelessWidget {
  final EduAcademicCourse course;
  final VoidCallback? onTap;

  const AcademicCourseItem({
    super.key,
    required this.course,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = _gradeColor(context);
    final gpaText =
        course.gpa == null ? '' : ' · 绩点 ${course.gpa!.toStringAsFixed(2)}';
    final nature = course.courseNature ?? course.courseCategory ?? '课程';

    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  course.courseName,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${course.credits.toStringAsFixed(1)} 学分 · $nature · ${course.displayStatus}$gpaText',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (course.hasRetake) ...[
                  const SizedBox(height: 3),
                  Text(
                    '原成绩 ${course.grade ?? '--'} · 补考 ${course.makeupGrade ?? '--'} · 重修 ${course.retakeGrade ?? '--'}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 6),
                _buildTags(context),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                course.displayGrade,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: Colors.grey[400],
                ),
            ],
          ),
        ],
      ),
    );

    return onTap == null ? child : InkWell(onTap: onTap, child: child);
  }

  Widget _buildTags(BuildContext context) {
    final tags = <String>[
      if (course.isDegree) '学位课',
      if (course.hasRetake) '重修',
      if (course.displayStatus.contains('在读')) '在读',
    ].take(2).toList();

    if (tags.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: tags.map((tag) => _tag(context, tag)).toList(),
    );
  }

  Widget _tag(BuildContext context, String text) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
      ),
    );
  }

  Color _gradeColor(BuildContext context) {
    if (course.effectivePassed == false) return Colors.red;
    if (course.displayStatus.contains('在读')) return Colors.grey;
    return Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black87;
  }
}
