/// 指定日期范围内的最小化课表课程出现项。
class ScheduleCourseOccurrence {
  const ScheduleCourseOccurrence({
    required this.date,
    required this.semesterId,
    required this.courseName,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    this.teacher,
    this.location,
  });

  final DateTime date;
  final String semesterId;
  final String courseName;
  final int weekday;
  final int startSection;
  final int endSection;
  final String? teacher;
  final String? location;
}

/// 供后续本地 Skill 使用的日期范围课表概览。
///
/// 此模型不包含保险箱 Payload、课程内部 ID、颜色、备注或来源账号。
class ScheduleOverview {
  ScheduleOverview({
    required this.start,
    required this.end,
    required List<String> availableSemesterIds,
    required List<ScheduleCourseOccurrence> occurrences,
    required this.termsWithoutStartDate,
  })  : availableSemesterIds = List<String>.unmodifiable(availableSemesterIds),
        occurrences = List<ScheduleCourseOccurrence>.unmodifiable(occurrences);

  final DateTime start;
  final DateTime end;
  final List<String> availableSemesterIds;
  final List<ScheduleCourseOccurrence> occurrences;
  final int termsWithoutStartDate;
}
