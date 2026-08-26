import 'package:flutter/material.dart';
import '../../models/edu_credit_requirement.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import 'academic_requirement_state.dart';

/// 可折叠的学分要求模块。
///
/// 标题行展示最低要求和已获学分，点击后在当前页面展开课程明细。
class AcademicRequirementCard extends StatefulWidget {
  final EduCreditRequirementModule module;

  const AcademicRequirementCard({
    super.key,
    required this.module,
  });

  @override
  State<AcademicRequirementCard> createState() =>
      _AcademicRequirementCardState();
}

class _AcademicRequirementCardState extends State<AcademicRequirementCard> {
  bool _isExpanded = false;

  EduCreditRequirementModule get module => widget.module;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBackground =
        isDark ? AppColors.surfaceSecondaryDark : AppColors.surfaceSecondaryLight;
    final headerBackground =
        isDark ? AppColors.brandSurfaceDark : AppColors.brandSurfaceLight;
    final borderColor =
        isDark ? AppColors.borderSubtleDark : AppColors.borderNormalLight;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: cardBackground,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            children: [
              _buildHeader(isDark, headerBackground),
              AnimatedOpacity(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : AppMotion.fast,
                curve: AppMotion.standard,
                opacity: _isExpanded ? 1 : 0,
                // 内容在状态切换时直接采用最终布局，避免长课程列表逐帧
                // 从 height=0 重新 layout 到完整高度。
                child: _isExpanded
                    ? _buildCourseList(isDark)
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(bool isDark, Color background) {
    final titleColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final summaryColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

    return Semantics(
      button: true,
      expanded: _isExpanded,
      child: InkWell(
        onTap: () => setState(() => _isExpanded = !_isExpanded),
        child: Ink(
          width: double.infinity,
          color: background,
          padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            module.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: titleColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AcademicRequirementState(status: module.status),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (module.requiredCredits != null)
                          Text(
                            '最低 ${_formatCredits(module.requiredCredits!)} 学分',
                            style: TextStyle(fontSize: 12, color: summaryColor),
                          ),
                        if (module.requiredCourseCount != null)
                          Text(
                            '最低 ${module.requiredCourseCount} 门',
                            style: TextStyle(fontSize: 12, color: summaryColor),
                          ),
                        Text(
                          '已获 ${_formatCredits(module.earnedCredits)} 学分',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.brandPrimary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              AnimatedRotation(
                turns: _isExpanded ? 0.5 : 0,
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : AppMotion.fast,
                curve: AppMotion.standard,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 24,
                  color: summaryColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCourseList(bool isDark) {
    final courses = module.courses;
    final subColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

    if (courses.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '暂无课程明细',
            style: TextStyle(fontSize: 13, color: subColor),
          ),
        ),
      );
    }

    return Column(
      children: [
        for (var index = 0; index < courses.length; index++) ...[
          if (index > 0)
            Divider(
              height: 1,
              indent: 14,
              endIndent: 14,
              color: isDark
                  ? AppColors.borderSubtleDark
                  : AppColors.borderSubtleLight,
            ),
          _RequirementCourseRow(course: courses[index]),
        ],
      ],
    );
  }

  String _formatCredits(double credits) {
    return credits.toStringAsFixed(
      credits.truncateToDouble() == credits ? 0 : 1,
    );
  }
}

class _RequirementCourseRow extends StatelessWidget {
  final EduRequirementCourse course;

  const _RequirementCourseRow({required this.course});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final subColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    final statusColor = course.completed == true
        ? AppColors.success
        : course.completed == false
            ? (isDark ? AppColors.textMutedLight : AppColors.textSecondaryLight)
            : AppColors.brandPrimary;

    final metadata = <String>[
      if (course.courseCode.isNotEmpty) course.courseCode,
      '${course.creditsText} 学分',
      if (course.actualTermText.isNotEmpty) course.actualTermText,
      if (course.courseNature != null) course.courseNature!,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              course.completed == true
                  ? Icons.check_circle_rounded
                  : course.completed == false
                      ? Icons.remove_circle_outline_rounded
                      : Icons.schedule_rounded,
              size: 18,
              color: statusColor,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        course.courseName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: titleColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      course.gradeText,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: subColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  metadata.join(' · '),
                  style: TextStyle(fontSize: 11, color: subColor),
                ),
                if (course.showSuggestedTerm) ...[
                  const SizedBox(height: 3),
                  Text(
                    '建议 ${course.suggestedTermText}',
                    style: TextStyle(fontSize: 11, color: subColor),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
