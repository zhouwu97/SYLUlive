import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

class AcademicCourseStatusState extends StatelessWidget {
  final String status;

  const AcademicCourseStatusState({
    super.key,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final presentation = _presentationFor(status);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = presentation.isWarning
        ? AppColors.warning
        : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight);

    return Padding(
      key: ValueKey('academic_course_status_$status'),
      padding: const EdgeInsets.fromLTRB(32, 30, 32, 50),
      child: Column(
        children: [
          Icon(presentation.icon, size: 28, color: foreground),
          const SizedBox(height: 10),
          Text(
            presentation.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: foreground,
              fontSize: 13,
              fontWeight:
                  presentation.isWarning ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  _AcademicCourseStatusPresentation _presentationFor(String value) {
    return switch (value) {
      'empty' => const _AcademicCourseStatusPresentation(
          text: '教务系统当前未返回课程明细',
          icon: Icons.inbox_outlined,
        ),
      'not_present' => const _AcademicCourseStatusPresentation(
          text: '当前学业页面不提供课程明细',
          icon: Icons.info_outline,
        ),
      'dynamic_source_unresolved' => const _AcademicCourseStatusPresentation(
          text: '课程明细可能通过其他接口加载，暂未完成识别',
          icon: Icons.manage_search_outlined,
        ),
      'parse_failed' => const _AcademicCourseStatusPresentation(
          text: '课程明细结构发生变化，暂时无法展示',
          icon: Icons.warning_amber_rounded,
          isWarning: true,
        ),
      _ => const _AcademicCourseStatusPresentation(
          text: '暂无可展示的课程明细',
          icon: Icons.info_outline,
        ),
    };
  }
}

class _AcademicCourseStatusPresentation {
  final String text;
  final IconData icon;
  final bool isWarning;

  const _AcademicCourseStatusPresentation({
    required this.text,
    required this.icon,
    this.isWarning = false,
  });
}
