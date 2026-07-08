import 'package:flutter/material.dart';
import '../campus/campus_theme.dart';

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
    final time = course['time']?.toString() ?? '0';
    final endTime = course['end_time']?.toString() ?? time;

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
              '第$time-$endTime节',
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
