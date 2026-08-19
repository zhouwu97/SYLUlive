import 'package:flutter/material.dart';
import '../../models/edu_credit_requirement.dart';

/// 提高课程卡片组件。
///
/// 使用中性颜色，不标记为风险或必选项。
class ImprovementCourseCard extends StatelessWidget {
  final EduRequirementCourse course;

  const ImprovementCourseCard({
    super.key,
    required this.course,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF737A80);
    final cardBg =
        isDark ? const Color(0xFF1A1D21) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : const Color(0xFFE2E6EB);
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF3F8F7A);

    final isFinished = course.completed == true;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 课程名称 + 状态
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  course.courseName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: titleColor,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isFinished
                      ? (isDark
                              ? const Color(0xFF7ED6C5)
                              : const Color(0xFF147C72))
                          .withValues(alpha: 0.1)
                      : Colors.grey.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  isFinished ? '已修读' : '未修读',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isFinished
                        ? accent
                        : (isDark ? Colors.grey.shade500 : const Color(0xFF8E959D)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // 学分 + 成绩
          Row(
            children: [
              Text(
                '${course.creditsText} 学分',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade300 : const Color(0xFF4A5058),
                ),
              ),
              if (isFinished && course.grade != null) ...[
                const SizedBox(width: 12),
                Text(
                  '·  ${course.grade}',
                  style: TextStyle(fontSize: 13, color: subColor),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),

          // 修读学期
          if (course.actualTermText.isNotEmpty)
            Text(
              course.actualTermText,
              style: TextStyle(fontSize: 12, color: subColor),
            ),

          // 建议修读学期
          if (course.showSuggestedTerm)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '建议：${course.suggestedTermText}',
                style: TextStyle(fontSize: 12, color: subColor),
              ),
            ),
        ],
      ),
    );
  }
}

/// 提高课程区域组件。
///
/// 在页面底部独立展示，不与普通模块混排。
class ImprovementCourseSection extends StatelessWidget {
  final List<EduRequirementCourse> courses;

  const ImprovementCourseSection({
    super.key,
    required this.courses,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '提高课程',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF1F2328),
            ),
          ),
          const SizedBox(height: 10),
          ...courses.map(
            (course) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ImprovementCourseCard(course: course),
            ),
          ),
        ],
      ),
    );
  }
}
