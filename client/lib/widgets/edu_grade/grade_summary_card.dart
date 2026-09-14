import 'package:flutter/material.dart';
import '../../models/edu_grade.dart';
import '../../utils/edu_semester_utils.dart';

class GradeSummaryCard extends StatelessWidget {
  final String selectedYear;
  final int selectedSemester;
  final List<EduGrade> grades;
  final bool hasValidData;
  final DateTime? updatedAt;
  final bool isRefreshing;

  const GradeSummaryCard({
    super.key,
    required this.selectedYear,
    required this.selectedSemester,
    required this.grades,
    this.hasValidData = true,
    this.updatedAt,
    this.isRefreshing = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final courseCount = hasValidData ? grades.length.toString() : '--';
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
                  Row(
                    children: [
                      Text(
                        '$courseCount 门课程',
                        style: TextStyle(
                          fontSize: 13,
                          color: subColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (isRefreshing) ...[
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            valueColor: AlwaysStoppedAnimation(accentColor),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isRefreshing
                        ? '正在连接教务…'
                        : (updatedAt == null
                            ? '暂无同步记录'
                            : '上次更新 ${updatedAt!.toLocal().month}月${updatedAt!.toLocal().day}日 ${updatedAt!.toLocal().hour.toString().padLeft(2, '0')}:${updatedAt!.toLocal().minute.toString().padLeft(2, '0')}'),
                    style: TextStyle(
                      fontSize: 12,
                      color: subColor,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: '学期 GPA 加权说明',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _showGpaExplanation(context),
                child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '学期 GPA',
                        style: TextStyle(
                          fontSize: 12,
                          color: subColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.info_outline_rounded,
                        size: 13,
                        color: subColor,
                      ),
                    ],
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
            ),
          ),
        ],
        ),
      ),
    );
  }

  void _showGpaExplanation(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E2226) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: isDark
                        ? const Color(0xFF7ED6C5)
                        : const Color(0xFF147C72),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '学期 GPA 计算说明',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : const Color(0xFF1F2328),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '• 计算公式：Σ(单科绩点 × 学分) ÷ Σ学分\n'
                '• 仅纳入当前学期教务已公布成绩且具备绩点的课程，无绩点或免修课程不参与加权。\n'
                '• 本处为客户端加权计算结果，最终评奖评优与官方成绩单请以学校教务系统为准。',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: isDark ? Colors.grey.shade300 : const Color(0xFF4A5056),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
