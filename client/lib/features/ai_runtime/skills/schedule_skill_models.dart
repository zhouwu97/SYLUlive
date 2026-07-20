class TodayScheduleInput {
  const TodayScheduleInput({this.date});

  final DateTime? date;
}

class WeekScheduleInput {
  const WeekScheduleInput({this.start, this.end, this.weekContaining});

  const WeekScheduleInput.containing(DateTime date)
      : start = null,
        end = null,
        weekContaining = date;

  final DateTime? start;
  final DateTime? end;
  final DateTime? weekContaining;
}

class ScheduleSkillCourse {
  const ScheduleSkillCourse({
    required this.date,
    required this.courseName,
    required this.startSection,
    required this.endSection,
    required this.timeText,
    this.teacher,
    this.location,
  });

  final DateTime date;
  final String courseName;
  final int startSection;
  final int endSection;
  final String timeText;
  final String? teacher;
  final String? location;
}

class ScheduleFreeTimeSlot {
  const ScheduleFreeTimeSlot({
    required this.startSection,
    required this.endSection,
    required this.timeText,
  });

  final int startSection;
  final int endSection;
  final String timeText;
}

class TodayScheduleOutput {
  TodayScheduleOutput({
    required this.date,
    required List<ScheduleSkillCourse> courses,
    required List<ScheduleFreeTimeSlot> freeTimeSlots,
    required this.dataUpdatedAt,
  })  : courses = List<ScheduleSkillCourse>.unmodifiable(courses),
        freeTimeSlots = List<ScheduleFreeTimeSlot>.unmodifiable(freeTimeSlots);

  final DateTime date;
  final List<ScheduleSkillCourse> courses;
  final List<ScheduleFreeTimeSlot> freeTimeSlots;
  final DateTime? dataUpdatedAt;
}

class WeekScheduleOutput {
  WeekScheduleOutput({
    required this.start,
    required this.end,
    required List<ScheduleSkillCourse> courses,
    required this.dataUpdatedAt,
    required this.termsWithoutStartDate,
  }) : courses = List<ScheduleSkillCourse>.unmodifiable(courses);

  final DateTime start;
  final DateTime end;
  final List<ScheduleSkillCourse> courses;
  final DateTime? dataUpdatedAt;
  final int termsWithoutStartDate;
}

const List<String> scheduleSectionStarts = <String>[
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

const List<String> scheduleSectionEnds = <String>[
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
  '20:10',
];

String scheduleTimeText(int startSection, int endSection) {
  if (startSection < 1 ||
      endSection < startSection ||
      endSection > scheduleSectionEnds.length) {
    return '第$startSection-$endSection节';
  }
  return '${scheduleSectionStarts[startSection - 1]}-'
      '${scheduleSectionEnds[endSection - 1]}';
}
