/// 学分要求模块详情页。
///
/// 展示单个模块的完整课程列表。

import 'package:flutter/material.dart';
import '../models/edu_credit_requirement.dart';
import '../theme/app_colors.dart';
import '../widgets/edu_grade/academic_requirement_state.dart';

class AcademicRequirementDetailScreen extends StatelessWidget {
  final EduCreditRequirementModule module;

  const AcademicRequirementDetailScreen({
    super.key,
    required this.module,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const accent = AppColors.brandPrimary;
    final titleColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final subColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

    return Scaffold(
      backgroundColor:
          isDark ? AppColors.surfacePrimaryDark : AppColors.surfacePrimaryLight,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          module.name,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // 模块进度卡片
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark
                  ? AppColors.surfaceSecondaryDark
                  : AppColors.surfaceSecondaryLight,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '模块进度',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 12),
                // 最低要求 vs 已获得
                Row(
                  children: [
                    if (module.hasRequiredCredits) ...[
                      Expanded(
                        child: _StatColumn(
                          label: '最低要求',
                          value: '${_formatCredits(module.requiredCredits!)} 学分',
                          isDark: isDark,
                          accent: accent,
                        ),
                      ),
                    ],
                    Expanded(
                      child: _StatColumn(
                        label: '已获得',
                        value: '${_formatCredits(module.earnedCredits)} 学分',
                        isDark: isDark,
                        accent: accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 状态
                Row(
                  children: [
                    Text(
                      '状态：',
                      style: TextStyle(fontSize: 13, color: subColor),
                    ),
                    AcademicRequirementState(status: module.status),
                  ],
                ),
                // 进度说明
                if (module.hasRequiredCredits) ...[
                  const SizedBox(height: 8),
                  if (module.progress >= 1.0)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: 1.0,
                        minHeight: 6,
                        backgroundColor: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : AppColors.brandSurfaceLight,
                        color: AppColors.success,
                      ),
                    )
                  else
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: module.progress,
                        minHeight: 6,
                        backgroundColor: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : AppColors.brandSurfaceLight,
                        color: _progressColor(module.status),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    module.creditDeltaText,
                    style: TextStyle(fontSize: 12, color: subColor),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 课程明细标题
          if (module.courses.isNotEmpty) ...[
            Text(
              '课程明细 · ${module.courses.length}门',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: titleColor,
              ),
            ),
            const SizedBox(height: 10),

            // 课程卡片列表
            for (final course in module.courses)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RequirementCourseCard(
                  course: course,
                  isDark: isDark,
                  titleColor: titleColor,
                  subColor: subColor,
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _formatCredits(double credits) {
    return credits.toStringAsFixed(
      credits.truncateToDouble() == credits ? 0 : 1,
    );
  }

  Color _progressColor(String status) {
    switch (status) {
      case 'completed':
        return AppColors.success;
      case 'in_progress':
        return AppColors.brandPrimary;
      case 'shortfall':
        return AppColors.warning;
      default:
        return AppColors.textMutedLight;
    }
  }
}

class _StatColumn extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;
  final Color accent;

  const _StatColumn({
    required this.label,
    required this.value,
    required this.isDark,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final subColor =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: accent,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(fontSize: 12, color: subColor),
        ),
      ],
    );
  }
}

class _RequirementCourseCard extends StatelessWidget {
  final EduRequirementCourse course;
  final bool isDark;
  final Color titleColor;
  final Color subColor;

  const _RequirementCourseCard({
    required this.course,
    required this.isDark,
    required this.titleColor,
    required this.subColor,
  });

  @override
  Widget build(BuildContext context) {
    final cardBg = isDark
        ? AppColors.surfaceSecondaryDark
        : AppColors.surfaceSecondaryLight;
    final borderColor =
        isDark ? AppColors.borderSubtleDark : AppColors.borderNormalLight;

    final isFinished = course.completed == true;
    final statusColor = isFinished
        ? AppColors.success
        : course.completed == false
            ? (isDark ? AppColors.textMutedLight : AppColors.textSecondaryLight)
            : AppColors.brandPrimary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第一行：课程名称 + 学分
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
              Text(
                '${course.creditsText}学分',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.grey.shade300 : const Color(0xFF4A5058),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // 第二行：课程号
          if (course.courseCode.isNotEmpty)
            Text(
              course.courseCode,
              style: TextStyle(fontSize: 12, color: subColor),
            ),
          const SizedBox(height: 8),

          // 第三行：实际修读学期
          if (course.actualTermText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                course.actualTermText,
                style: TextStyle(fontSize: 12, color: subColor),
              ),
            ),

          // 第四行：课程性质 + 成绩/状态
          const SizedBox(height: 2),
          Row(
            children: [
              if (course.courseNature != null &&
                  course.courseNature!.isNotEmpty)
                Expanded(
                  child: Text(
                    course.courseNature!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: subColor),
                  ),
                )
              else
                const Spacer(),
              const SizedBox(width: 8),
              Text(
                '${course.gradeText} · ${course.statusText}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
            ],
          ),

          // 建议修读学期
          if (course.showSuggestedTerm)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '建议修读：${course.suggestedTermText}',
                style: TextStyle(fontSize: 12, color: subColor),
              ),
            ),
        ],
      ),
    );
  }
}
