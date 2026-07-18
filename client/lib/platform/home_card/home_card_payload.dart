import '../../providers/course_schedule_provider.dart';
import '../../utils/course_section_times.dart';

/// 互动卡片的单行展示数据，不包含学号、成绩等敏感信息。
class HomeCardItem {
  const HomeCardItem({
    required this.title,
    required this.primary,
    this.secondary = '',
    this.badge = '',
  });

  final String title;
  final String primary;
  final String secondary;
  final String badge;

  Map<String, Object?> toJson() => {
        'title': title,
        'primary': primary,
        'secondary': secondary,
        'badge': badge,
      };
}

/// Flutter 与鸿蒙卡片扩展之间的稳定 JSON 协议。
class HomeCardPayload {
  const HomeCardPayload({
    required this.title,
    required this.subtitle,
    required this.items,
    required this.updatedAt,
    this.featuredIndex = 0,
  });

  final String title;
  final String subtitle;
  final List<HomeCardItem> items;
  final DateTime updatedAt;
  final int featuredIndex;

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'title': title,
        'subtitle': subtitle,
        'empty': items.isEmpty,
        'items': items.map((item) => item.toJson()).toList(growable: false),
        'updatedAt': updatedAt.toIso8601String(),
        'featuredIndex': featuredIndex,
      };
}

class HomeCardExamData {
  const HomeCardExamData({
    required this.name,
    required this.startTime,
    required this.endTime,
    required this.location,
  });

  final String name;
  final DateTime startTime;
  final DateTime endTime;
  final String location;
}

/// 只负责把现有业务数据投影为卡片展示数据，不进行网络请求或数据写入。
class HomeCardPayloadFactory {
  HomeCardPayloadFactory._();

  static HomeCardPayload course(
    CourseScheduleProvider provider, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final academicWeek = provider.getAcademicWeek(current);
    final courses = provider.courses.where((course) {
      if (course.weekday != current.weekday) return false;
      return academicWeek == null ||
          provider.isCourseActive(course, academicWeek);
    }).toList()
      ..sort((left, right) => left.startSection.compareTo(right.startSection));

    final items = courses.map((course) {
      return HomeCardItem(
        title: course.name,
        primary: '${CourseSectionTimes.startLabel(course.startSection)}-'
            '${CourseSectionTimes.endLabel(course.endSection)}',
        secondary: course.location?.trim() ?? '',
        badge: '第${course.startSection}-${course.endSection}节',
      );
    }).toList(growable: false);
    final minuteOfDay = current.hour * 60 + current.minute;
    var featuredIndex = 0;
    for (var index = 0; index < courses.length; index++) {
      final course = courses[index];
      final endText = CourseSectionTimes.endLabel(course.endSection);
      final parts = endText.split(':');
      final endMinute = int.parse(parts[0]) * 60 + int.parse(parts[1]);
      if (endMinute >= minuteOfDay) {
        featuredIndex = index;
        break;
      }
      featuredIndex = index + 1;
    }

    final weekText = academicWeek == null ? '' : ' · 第$academicWeek周';
    return HomeCardPayload(
      title: '今日课程',
      subtitle: '${current.month}月${current.day}日$weekText',
      items: items,
      updatedAt: current,
      featuredIndex:
          featuredIndex.clamp(0, items.isEmpty ? 0 : items.length - 1),
    );
  }

  static HomeCardPayload exam(
    Iterable<HomeCardExamData> source, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final exams = source
        .where((exam) => exam.endTime.isAfter(current))
        .toList(growable: false)
      ..sort((left, right) => left.startTime.compareTo(right.startTime));

    return HomeCardPayload(
      title: '考试提醒',
      subtitle: exams.isEmpty ? '暂无待考安排' : '未来 ${exams.length} 场',
      items: exams
          .map(
            (exam) => HomeCardItem(
              title: exam.name,
              primary:
                  '${exam.startTime.month}月${exam.startTime.day}日 ${_time(exam.startTime)}-${_time(exam.endTime)}',
              secondary:
                  exam.location.trim().isEmpty ? '地点待定' : exam.location.trim(),
              badge: _countdown(exam.startTime, current),
            ),
          )
          .toList(growable: false),
      updatedAt: current,
    );
  }

  static HomeCardPayload competition(
    Iterable<Map<String, dynamic>> source, {
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final entries = source
        .where((item) => !const {'finished', 'archived'}.contains(
              '${item['plan_status'] ?? ''}'.trim(),
            ))
        .map((item) {
      final deadline = _parseDate(item['user_deadline']) ??
          _parseDate(item['registration_end']) ??
          _parseDate(item['event_start']);
      return (item: item, deadline: deadline);
    }).toList(growable: false)
      ..sort((left, right) {
        final leftDate = left.deadline;
        final rightDate = right.deadline;
        if (leftDate == null) return rightDate == null ? 0 : 1;
        if (rightDate == null) return -1;
        return leftDate.compareTo(rightDate);
      });

    return HomeCardPayload(
      title: '竞赛计划',
      subtitle: entries.isEmpty ? '暂无竞赛提醒' : '关注 ${entries.length} 项',
      items: entries.map((entry) {
        final item = entry.item;
        final deadline = entry.deadline;
        return HomeCardItem(
          title: '${item['title'] ?? '未命名比赛'}',
          primary: deadline == null
              ? '${item['registration_time_text'] ?? '时间待定'}'
              : '${deadline.month}月${deadline.day}日截止',
          secondary: '${item['location'] ?? ''}'.trim(),
          badge: _planStatusLabel('${item['plan_status'] ?? ''}'),
        );
      }).toList(growable: false),
      updatedAt: current,
    );
  }

  static String _time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  static String _countdown(DateTime target, DateTime now) {
    final days = DateTime(target.year, target.month, target.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    if (days < 0) return '进行中';
    if (days == 0) return '今天';
    if (days == 1) return '明天';
    return '$days天后';
  }

  static DateTime? _parseDate(dynamic value) {
    final raw = '${value ?? ''}'.trim();
    if (raw.isEmpty || raw == 'null') return null;
    return DateTime.tryParse(raw);
  }

  static String _planStatusLabel(String value) => switch (value.trim()) {
        'preparing' => '准备中',
        'registered' => '已报名',
        'submitted' => '已提交',
        _ => '关注中',
      };
}
