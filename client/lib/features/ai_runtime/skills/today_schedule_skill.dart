import '../../campus_data/storage/personal_snapshot_models.dart';
import '../personal_data/models/schedule_overview.dart';
import 'gateway_skill_support.dart';
import 'personal_skill.dart';
import 'schedule_skill_models.dart';
import 'skill_execution_context.dart';

class TodayScheduleSkill
    implements PersonalSkill<TodayScheduleInput, TodayScheduleOutput> {
  static const String skillId = 'personal.schedule.today';
  static const int _maximumCourses = 32;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.low;

  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.schedule};

  @override
  Future<SkillResult<TodayScheduleOutput>> execute(
    TodayScheduleInput input,
    SkillExecutionContext context,
  ) async {
    final date = _dateOnly(input.date ?? context.now());
    final gateway = await context.getScheduleOverview(start: date, end: date);
    final failure = gatewayFailure<TodayScheduleOutput, ScheduleOverview>(
      gateway,
      dataLabel: '课表',
    );
    if (failure != null) return failure;

    final occurrences = gateway.data!.occurrences
        .where((item) => _sameDate(item.date, date))
        .take(_maximumCourses)
        .toList(growable: false);
    final truncated = gateway.data!.occurrences.length > occurrences.length;
    final courses = occurrences.map(_toCourse).toList(growable: false);
    final warnings = mergeWarnings(
      gateway.warnings,
      <String>[
        if (gateway.data!.termsWithoutStartDate > 0) '部分学期缺少起始日期',
        if (truncated) '今日课程数量超过上限，仅返回前 $_maximumCourses 条',
      ],
    );
    return SkillResult<TodayScheduleOutput>(
      value: TodayScheduleOutput(
        date: date,
        courses: courses,
        freeTimeSlots: _freeTimeSlots(occurrences),
        dataUpdatedAt: gateway.fetchedAt,
      ),
      status: gateway.data!.termsWithoutStartDate > 0 || truncated
          ? SkillStatus.partial
          : SkillStatus.success,
      evidence: <SkillEvidence>[
        gatewayEvidence(
          gateway,
          dataType: PersonalDataType.schedule,
          scope: '仅$date 当日课表',
        ),
      ],
      warnings: warnings,
      containsPersonalData: true,
    );
  }

  static ScheduleSkillCourse _toCourse(ScheduleCourseOccurrence occurrence) =>
      ScheduleSkillCourse(
        date: occurrence.date,
        courseName: occurrence.courseName,
        startSection: occurrence.startSection,
        endSection: occurrence.endSection,
        timeText: scheduleTimeText(
          occurrence.startSection,
          occurrence.endSection,
        ),
        teacher: occurrence.teacher,
        location: occurrence.location,
      );

  static List<ScheduleFreeTimeSlot> _freeTimeSlots(
    List<ScheduleCourseOccurrence> occurrences,
  ) {
    const firstSection = 1;
    final lastSection = scheduleSectionEnds.length;
    final occupied = occurrences
        .map(
          (item) => (
            item.startSection.clamp(firstSection, lastSection),
            item.endSection.clamp(firstSection, lastSection),
          ),
        )
        .where((range) => range.$1 <= range.$2)
        .toList()
      ..sort((left, right) => left.$1.compareTo(right.$1));

    final merged = <(int, int)>[];
    for (final range in occupied) {
      if (merged.isEmpty || range.$1 > merged.last.$2 + 1) {
        merged.add(range);
      } else if (range.$2 > merged.last.$2) {
        merged[merged.length - 1] = (merged.last.$1, range.$2);
      }
    }

    final result = <ScheduleFreeTimeSlot>[];
    var cursor = firstSection;
    for (final range in merged) {
      if (cursor < range.$1) result.add(_freeSlot(cursor, range.$1 - 1));
      cursor = range.$2 + 1;
    }
    if (cursor <= lastSection) result.add(_freeSlot(cursor, lastSection));
    return result;
  }

  static ScheduleFreeTimeSlot _freeSlot(int start, int end) =>
      ScheduleFreeTimeSlot(
        startSection: start,
        endSection: end,
        timeText: scheduleTimeText(start, end),
      );

  static DateTime _dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  static bool _sameDate(DateTime left, DateTime right) =>
      left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}
