import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

/// 导入预览同时承接本机教务和历史代理两种标准化结果，统一在这里读取坐标字段。
///
/// 本机链路输出 `weekday/start_section/end_section`，历史代理保留
/// `week_day/time/end_time`。字段缺失时显式保留为 0，避免误显示为周一或第 0 节。
class CoursePreviewFields {
  const CoursePreviewFields._();

  static int weekDay(Map<String, dynamic> course) {
    final value = _firstInt(course, const [
      'weekday',
      'week_day',
      'dayOfWeek',
      'day_of_week',
      'xqj',
    ]);
    return value != null && value >= 1 && value <= 7 ? value : 0;
  }

  static int startSection(Map<String, dynamic> course) {
    return _firstInt(course, const [
          'start_section',
          'startSection',
          'time',
          'start_time',
          'jc_start',
        ]) ??
        0;
  }

  static int endSection(Map<String, dynamic> course, int startSection) {
    return _firstInt(course, const [
          'end_section',
          'endSection',
          'end_time',
          'jc_end',
        ]) ??
        startSection;
  }

  static bool hasValidCoordinate(Map<String, dynamic> course) {
    final start = startSection(course);
    final end = endSection(course, start);
    return weekDay(course) > 0 && start > 0 && end >= start;
  }

  static int? _firstInt(Map<String, dynamic> course, List<String> keys) {
    for (final key in keys) {
      final value = course[key];
      final parsed = switch (value) {
        num() => value.toInt(),
        _ => int.tryParse(value?.toString().trim() ?? ''),
      };
      if (parsed != null) return parsed;
    }
    return null;
  }
}

class CoursePreviewTile extends StatelessWidget {
  final Map<String, dynamic> course;
  final bool isDark;

  const CoursePreviewTile({
    super.key,
    required this.course,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final name = course['name']?.toString() ?? '未知课程';
    final location = course['location']?.toString();
    final teacher = course['teacher']?.toString();
    final startSection = CoursePreviewFields.startSection(course);
    final endSection = CoursePreviewFields.endSection(course, startSection);
    final hasValidSection = startSection > 0 && endSection >= startSection;

    String weekStr = '';
    final rawWeeks = course['weeks'];
    if (rawWeeks is List && rawWeeks.isNotEmpty) {
      final List<int> weeks = rawWeeks.map((e) => (e as num).toInt()).toList();
      weeks.sort();
      if (weeks.length > 1 && weeks.last - weeks.first == weeks.length - 1) {
        weekStr = '${weeks.first}-${weeks.last}周';
      } else {
        weekStr = '${weeks.join(',')}周';
      }
    } else {
      weekStr = '周次未知';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkCard : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white12 : CampusTheme.softBorder,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: CampusTheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              hasValidSection ? '第$startSection-$endSection节' : '节次未知',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: CampusTheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : CampusTheme.text,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 6),
                if (location != null && location.isNotEmpty ||
                    teacher != null && teacher.isNotEmpty)
                  Row(
                    children: [
                      const Icon(Icons.location_on_rounded,
                          size: 14, color: CampusTheme.subText),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          [location, teacher]
                              .where((e) => e != null && e.isNotEmpty)
                              .join(' · '),
                          style: const TextStyle(
                            fontSize: 12,
                            color: CampusTheme.subText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.date_range_rounded,
                        size: 14, color: CampusTheme.subText),
                    const SizedBox(width: 4),
                    Text(
                      weekStr,
                      style: const TextStyle(
                        fontSize: 12,
                        color: CampusTheme.subText,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
