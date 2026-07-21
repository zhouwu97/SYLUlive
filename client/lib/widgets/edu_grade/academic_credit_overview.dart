import 'package:flutter/material.dart';

import '../../models/edu_academic_situation.dart';

class AcademicCreditOverview extends StatelessWidget {
  final EduAcademicSituation situation;

  const AcademicCreditOverview({
    super.key,
    required this.situation,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF737A80);
    final totals = situation.courses.isEmpty
        ? null
        : _CreditTotals.fromCourses(situation.courses);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '学分概览',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 10),
          if (totals == null)
            Text(
              '暂无可汇总的课程学分数据',
              style: TextStyle(fontSize: 13, color: subColor),
            )
          else ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final itemWidth = (constraints.maxWidth - 16) / 3;
                return Wrap(
                  spacing: 8,
                  runSpacing: 12,
                  children: [
                    _CreditMetric(
                      width: itemWidth,
                      label: '课程列表学分',
                      value: totals.total,
                      subColor: subColor,
                    ),
                    _CreditMetric(
                      width: itemWidth,
                      label: '已通过学分',
                      value: totals.passed,
                      subColor: subColor,
                    ),
                    _CreditMetric(
                      width: itemWidth,
                      label: '未通过学分',
                      value: totals.failed,
                      subColor: subColor,
                    ),
                    _CreditMetric(
                      width: itemWidth,
                      label: '修读中学分',
                      value: totals.inProgress,
                      subColor: subColor,
                    ),
                    _CreditMetric(
                      width: itemWidth,
                      label: '尚未修读学分',
                      value: totals.notStarted,
                      subColor: subColor,
                    ),
                    _CreditMetric(
                      width: itemWidth,
                      label: '未知状态学分',
                      value: totals.unknown,
                      subColor: subColor,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Text(
              '课程列表学分包含修读中、尚未修读和未知状态课程，不代表已获得学分。',
              style: TextStyle(fontSize: 11, height: 1.4, color: subColor),
            ),
          ],
        ],
      ),
    );
  }
}

class _CreditMetric extends StatelessWidget {
  final double width;
  final String label;
  final double value;
  final Color subColor;

  const _CreditMetric({
    required this.width,
    required this.label,
    required this.value,
    required this.subColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_formatCredits(value)} 学分',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(fontSize: 12, color: subColor)),
        ],
      ),
    );
  }

  String _formatCredits(double credits) {
    return credits.toStringAsFixed(
      credits.truncateToDouble() == credits ? 0 : 1,
    );
  }
}

class _CreditTotals {
  final double total;
  final double passed;
  final double failed;
  final double inProgress;
  final double notStarted;
  final double unknown;

  const _CreditTotals({
    required this.total,
    required this.passed,
    required this.failed,
    required this.inProgress,
    required this.notStarted,
    required this.unknown,
  });

  factory _CreditTotals.fromCourses(List<EduAcademicCourse> courses) {
    var passed = 0.0;
    var failed = 0.0;
    var inProgress = 0.0;
    var notStarted = 0.0;
    var unknown = 0.0;

    for (final course in courses) {
      if (course.effectivePassed == true) {
        passed += course.credits;
      } else if (course.effectivePassed == false) {
        failed += course.credits;
      } else if (_containsAny(course.studyStatus, const ['在读', '修读中', '在修'])) {
        inProgress += course.credits;
      } else if (_containsAny(course.studyStatus, const ['未修', '未开始'])) {
        notStarted += course.credits;
      } else {
        unknown += course.credits;
      }
    }

    return _CreditTotals(
      total: courses.fold(0, (sum, course) => sum + course.credits),
      passed: passed,
      failed: failed,
      inProgress: inProgress,
      notStarted: notStarted,
      unknown: unknown,
    );
  }

  static bool _containsAny(String? value, List<String> candidates) {
    final normalized = value?.trim() ?? '';
    return candidates.any(normalized.contains);
  }
}
