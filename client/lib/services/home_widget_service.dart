import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import '../providers/course_schedule_provider.dart';

/// 桌面小部件数据同步服务
///
/// 在课表数据刷新后，将当天课程信息写入原生 SharedPreferences / UserDefaults，
/// 并触发原生 widget 刷新。
class HomeWidgetService {
  static const String _androidWidgetName =
      'CourseScheduleWidgetProvider';
  static const String _iOSWidgetName = 'CourseScheduleWidget';

  // 与原生 Kotlin/Swift 端一致的 key
  static const String _keyTitle = 'widget_title';
  static const String _keyDate = 'widget_date';
  static const String _keyContent = 'widget_content';
  static const String _keyEmpty = 'widget_empty';

  static bool _callbackRegistered = false;

  /// 初始化：注册后台更新回调（Android 需要）
  static Future<void> initialize() async {
    if (_callbackRegistered) return;
    try {
      await HomeWidget.registerInteractivityCallback(_backgroundCallback);
      _callbackRegistered = true;
      debugPrint('✅ HomeWidget 后台回调已注册');
    } catch (e) {
      debugPrint('HomeWidget 注册回调失败 (可能非 Android): $e');
    }
  }

  /// 后台更新回调 — Android 系统定时触发时调用
  @pragma('vm:entry-point')
  static Future<bool> _backgroundCallback(Uri? uri) async {
    // 后台无法访问 Provider，只能从 SharedPreferences 读取已缓存数据并返回 true 表示已更新
    // 实际 UI 渲染由原生 AppWidgetProvider 从 SharedPreferences 读取完成
    return true;
  }

  /// 同步当天课表到桌面小部件
  ///
  /// [provider] 课程数据提供者，需已加载数据
  static Future<void> syncTodayCourses(CourseScheduleProvider provider) async {
    try {
      final now = DateTime.now();
      final weekday = now.weekday; // 1=周一 .. 7=周日
      final academicWeek = provider.getAcademicWeek(now);

      // 标题
      const title = '沈理院课表';

      // 日期信息
      final weekName = ['', '一', '二', '三', '四', '五', '六', '日'][weekday];
      final weekStr = academicWeek != null ? '第$academicWeek周' : '';
      final date =
          '${now.month}.${now.day} $weekStr 周$weekName';

      // 筛选当天的课
      final todayCourses = provider.courses.where((c) {
        if (c.weekday != weekday) return false;
        if (academicWeek != null && !provider.isCourseActive(c, academicWeek)) {
          return false;
        }
        return true;
      }).toList();

      // 按开始节次排序
      todayCourses.sort((a, b) => a.startSection.compareTo(b.startSection));

      final isEmpty = todayCourses.isEmpty;
      String content = '';

      if (!isEmpty) {
        // 格式：课程名|时间|地点（换行分隔多条）
        final lines = <String>[];
        // 上课时间表（与 course_schedule_screen 保持一致）
        const starts = [
          '08:00', '08:55', '10:00', '10:55',
          '13:00', '13:55', '14:50', '15:45',
          '16:40', '17:35', '18:30', '19:25'
        ];
        const ends = [
          '08:45', '09:40', '10:45', '11:40',
          '13:45', '14:40', '15:35', '16:30',
          '17:25', '18:20', '19:15', '20:10'
        ];

        for (final course in todayCourses) {
          final startIdx = (course.startSection - 1).clamp(0, 11);
          final endIdx = (course.endSection - 1).clamp(0, 11);
          final timeStr = '${starts[startIdx]}-${ends[endIdx]}';
          final locStr = course.location ?? '';
          lines.add('${course.name}|$timeStr|$locStr');
        }
        content = lines.join('\n');
      }

      // 写入原生存储
      await HomeWidget.saveWidgetData(_keyTitle, title);
      await HomeWidget.saveWidgetData(_keyDate, date);
      await HomeWidget.saveWidgetData(_keyContent, content);
      await HomeWidget.saveWidgetData(_keyEmpty, isEmpty);

      // 触发原生 widget 刷新
      await HomeWidget.updateWidget(
        androidName: _androidWidgetName,
        iOSName: _iOSWidgetName,
      );

      debugPrint(
          '✅ 小部件已更新: ${todayCourses.length}门课, 日期=$date');
    } catch (e) {
      debugPrint('小部件同步失败: $e');
    }
  }
}
