import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import '../campus/campus_theme.dart';
import '../../providers/course_schedule_provider.dart';
import '../../providers/edu_provider.dart';
import 'course_preview_tile.dart';

class CoursePreviewSheet extends StatelessWidget {
  final List<Map<String, dynamic>> courses;
  final String year;
  final int semester;
  final EduProvider eduProvider;

  const CoursePreviewSheet({
    super.key,
    required this.courses,
    required this.year,
    required this.semester,
    required this.eduProvider,
  });

  static Future<bool?> show(
    BuildContext context, {
    required List<Map<String, dynamic>> courses,
    required String year,
    required int semester,
    required EduProvider eduProvider,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => CoursePreviewSheet(
        courses: courses,
        year: year,
        semester: semester,
        eduProvider: eduProvider,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 按星期分组
    final Map<int, List<Map<String, dynamic>>> grouped = {};
    for (var c in courses) {
      final wd = (c['week_day'] as num?)?.toInt() ?? 1;
      grouped.putIfAbsent(wd, () => []).add(c);
    }

    // 排序
    for (var list in grouped.values) {
      list.sort((a, b) {
        final ta = (a['time'] as num?)?.toInt() ?? 0;
        final tb = (b['time'] as num?)?.toInt() ?? 0;
        return ta.compareTo(tb);
      });
    }

    final sortedKeys = grouped.keys.toList()..sort();
    final weekNames = ['一', '二', '三', '四', '五', '六', '日'];

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkBg : CampusTheme.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.black12,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$year-${int.parse(year) + 1} 第${semester == 3 ? "一" : "二"}学期课表',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : CampusTheme.text,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '共 ${courses.length} 门课 · ${sortedKeys.length} 个上课日',
                        style: const TextStyle(
                          fontSize: 13,
                          color: CampusTheme.subText,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded,
                      color: CampusTheme.subText),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: courses.isEmpty
                ? const Center(
                    child: Text('暂无课程，尝试重新获取',
                        style: TextStyle(color: CampusTheme.subText)))
                : ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    itemCount: sortedKeys.length,
                    itemBuilder: (context, index) {
                      final wd = sortedKeys[index];
                      final list = grouped[wd]!;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 8, bottom: 12),
                            child: Text(
                              '周${wd >= 1 && wd <= 7 ? weekNames[wd - 1] : wd}',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : CampusTheme.text,
                              ),
                            ),
                          ),
                          ...list.map((c) =>
                              CoursePreviewTile(course: c, isDark: isDark)),
                        ],
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ElevatedButton(
                onPressed: () {
                  Navigator.pop(context, true);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: CampusTheme.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  minimumSize: const Size(double.infinity, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  '导入到课表',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
