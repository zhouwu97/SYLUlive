import '../models/exam_schedule.dart';
import '../providers/course_schedule_provider.dart';

enum CampusTodayEntryKind { course, exam }

enum CampusTodayCourseState { active, upcoming }

/// 今日卡片使用的纯展示模型；时间判定在此完成，页面只负责映射点击行为。
class CampusTodayEntry {
  const CampusTodayEntry({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.courseState,
  });

  final String id;
  final CampusTodayEntryKind kind;
  final String title;
  final String subtitle;
  final CampusTodayCourseState? courseState;
}

/// 按本地时间选出正在进行或即将开始的唯一课程，并附加最近考试。
///
/// 课程窗口按课表节次的开始时间和结束节次后的 45 分钟计算；调用方应先按
/// 当前教学周过滤课程，这样本函数可保持纯函数且不会触发任何数据读取。
List<CampusTodayEntry> buildCampusTodayEntries({
  required DateTime now,
  required Iterable<CourseBlock> courses,
  required Iterable<ExamModel> exams,
}) {
  final entries = <CampusTodayEntry>[];
  final todayCourses = courses
      .where((course) => course.weekday == now.weekday)
      .map((course) => _courseWindow(course, now))
      .whereType<_CourseWindow>()
      .toList()
    ..sort((left, right) => left.start.compareTo(right.start));

  _CourseWindow? selectedCourse;
  CampusTodayCourseState? courseState;
  for (final course in todayCourses) {
    if (!now.isBefore(course.start) && now.isBefore(course.end)) {
      selectedCourse = course;
      courseState = CampusTodayCourseState.active;
      break;
    }
    if (now.isBefore(course.start)) {
      selectedCourse = course;
      courseState = CampusTodayCourseState.upcoming;
      break;
    }
  }

  if (selectedCourse != null && courseState != null) {
    final course = selectedCourse.course;
    final location = _optionalPart(course.location);
    final teacher = _optionalPart(course.teacher);
    final suffix = '$location$teacher';
    final title = courseState == CampusTodayCourseState.active
        ? '正在上课 · ${course.name}'
        : '下一节课 · ${course.name}';
    final time = courseState == CampusTodayCourseState.active
        ? '现在 ${_formatClock(selectedCourse.start)}–${_formatClock(selectedCourse.end)}'
        : '今天 ${_formatClock(selectedCourse.start)}';
    entries.add(CampusTodayEntry(
      id: 'next-class',
      kind: CampusTodayEntryKind.course,
      title: title,
      subtitle: '$time$suffix',
      courseState: courseState,
    ));
  }

  final nextExam = exams
      .where((exam) => exam.endTime.isAfter(now))
      .where((exam) => exam.name.trim().isNotEmpty)
      .toList()
    ..sort((left, right) => left.startTime.compareTo(right.startTime));
  if (nextExam.isNotEmpty) {
    final exam = nextExam.first;
    final location = _optionalPart(exam.location);
    final timing = exam.startTime.isAfter(now)
        ? _formatExamStart(exam.startTime, now)
        : '进行中 · ${_formatClock(exam.startTime)}';
    entries.add(CampusTodayEntry(
      id: 'next-exam',
      kind: CampusTodayEntryKind.exam,
      title: '考试 · ${exam.name}',
      subtitle: '$timing$location',
    ));
  }
  return entries;
}

class _CourseWindow {
  const _CourseWindow({
    required this.course,
    required this.start,
    required this.end,
  });

  final CourseBlock course;
  final DateTime start;
  final DateTime end;
}

_CourseWindow? _courseWindow(CourseBlock course, DateTime day) {
  final start = _sectionTime(course.startSection, day);
  final endSection = course.endSection.clamp(course.startSection, 12);
  final endStart = _sectionTime(endSection, day);
  if (start == null || endStart == null) return null;
  return _CourseWindow(
    course: course,
    start: start,
    end: endStart.add(const Duration(minutes: 45)),
  );
}

DateTime? _sectionTime(int section, DateTime day) {
  const starts = <String>[
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
    '19:25',
  ];
  if (section < 1 || section > starts.length) return null;
  final parts = starts[section - 1].split(':');
  return DateTime(
    day.year,
    day.month,
    day.day,
    int.parse(parts[0]),
    int.parse(parts[1]),
  );
}

String _formatClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String _formatExamStart(DateTime start, DateTime now) {
  final sameDay = _sameDate(start, now);
  if (sameDay) return '今天 ${_formatClock(start)}';
  final tomorrow = now.add(const Duration(days: 1));
  if (_sameDate(start, tomorrow)) return '明天 ${_formatClock(start)}';
  return '${start.month}月${start.day}日 ${_formatClock(start)}';
}

String _optionalPart(String? value) {
  final text = value?.trim() ?? '';
  return text.isEmpty ? '' : ' · $text';
}

bool _sameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
