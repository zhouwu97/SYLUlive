import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/course_schedule_provider.dart';

/// 桌面小部件数据同步服务
///
/// 将当天课程信息序列化为 JSON 写入 SharedPreferences，
/// 通过 MethodChannel 通知原生 Kotlin 端更新 Glance widget。
/// WorkManager 在后台周期刷新，确保开机和定时更新。
class HomeWidgetService {
  static const _channel = MethodChannel('shenliyuan/widget');

  static const _key = 'widget_course_data';

  /// 同步当天课表到桌面小部件（非阻塞）
  static Future<void> syncTodayCourses(CourseScheduleProvider provider) async {
    try {
      final now = DateTime.now();
      final weekday = now.weekday;
      final academicWeek = provider.getAcademicWeek(now);

      const title = '沈理院课表';

      final weekName = ['', '一', '二', '三', '四', '五', '六', '日'][weekday];
      final weekStr = academicWeek != null ? '第$academicWeek周' : '';
      final date = '${now.month}.${now.day} $weekStr 周$weekName';

      // 筛选当天的课
      final todayCourses = provider.courses.where((c) {
        if (c.weekday != weekday) return false;
        if (academicWeek != null && !provider.isCourseActive(c, academicWeek)) {
          return false;
        }
        return true;
      }).toList()
        ..sort((a, b) => a.startSection.compareTo(b.startSection));

      // 上课时间表
      const starts = [
        '08:00',
        '08:55',
        '10:00',
        '10:55',
        '13:00',
        '13:55',
        '14:50',
        '15:45',
        '16:40',
        '17:35',
        '18:30',
        '19:25'
      ];
      const ends = [
        '08:45',
        '09:40',
        '10:45',
        '11:40',
        '13:45',
        '14:40',
        '15:35',
        '16:30',
        '17:25',
        '18:20',
        '19:15',
        '20:10'
      ];

      final coursesJson = todayCourses.map((c) {
        final startIdx = (c.startSection - 1).clamp(0, 11);
        final endIdx = (c.endSection - 1).clamp(0, 11);
        return {
          'name': c.name,
          'time': '${starts[startIdx]}-${ends[endIdx]}',
          'location': c.location ?? '',
          'teacher': c.teacher ?? '',
          'color': c.color,
        };
      }).toList();

      final prefs = await SharedPreferences.getInstance();
      final textColor = prefs.getString('widget_text_color') ?? '#333333';

      final json = jsonEncode({
        'title': title,
        'date': date,
        'textColor': textColor,
        'courses': coursesJson,
      });

      // 写入 SharedPreferences（Flutter 端，key 会被自动加 flutter. 前缀）
      await prefs.setString(_key, json);

      // 通过 MethodChannel 通知原生端立即刷新 widget
      try {
        await _channel.invokeMethod('updateWidget');
      } catch (e) {
        debugPrint('原生 widget 刷新调用失败: $e');
      }

      debugPrint('✅ 小部件数据已写入: ${todayCourses.length}门课, 日期=$date');
    } catch (e) {
      debugPrint('小部件同步失败: $e');
    }
  }
}
