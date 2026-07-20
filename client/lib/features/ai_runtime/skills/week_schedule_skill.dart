import '../../campus_data/storage/personal_snapshot_models.dart';
import '../personal_data/models/schedule_overview.dart';
import 'gateway_skill_support.dart';
import 'personal_skill.dart';
import 'schedule_skill_models.dart';
import 'skill_execution_context.dart';

class WeekScheduleSkill
    implements PersonalSkill<WeekScheduleInput, WeekScheduleOutput> {
  static const String skillId = 'personal.schedule.week';
  static const int _maximumRangeDays = 7;
  static const int _maximumCourses = 128;

  @override
  String get id => skillId;

  @override
  SkillSensitivity get sensitivity => SkillSensitivity.low;

  @override
  Set<PersonalDataType> get requiredDataTypes =>
      const <PersonalDataType>{PersonalDataType.schedule};

  @override
  Future<SkillResult<WeekScheduleOutput>> execute(
    WeekScheduleInput input,
    SkillExecutionContext context,
  ) async {
    final range = _resolveRange(input, context.now());
    if (range == null) {
      return SkillResult<WeekScheduleOutput>(
        status: SkillStatus.invalidInput,
        containsPersonalData: false,
        warnings: const <String>['本周课表日期范围必须完整且不超过 7 天'],
      );
    }

    final gateway = await context.getScheduleOverview(
      start: range.$1,
      end: range.$2,
    );
    final failure = gatewayFailure<WeekScheduleOutput, ScheduleOverview>(
      gateway,
      dataLabel: '课表',
    );
    if (failure != null) return failure;

    final occurrences =
        gateway.data!.occurrences.take(_maximumCourses).toList(growable: false);
    final truncated = gateway.data!.occurrences.length > occurrences.length;
    final courses = occurrences
        .map(
          (item) => ScheduleSkillCourse(
            date: item.date,
            courseName: item.courseName,
            startSection: item.startSection,
            endSection: item.endSection,
            timeText: scheduleTimeText(item.startSection, item.endSection),
            teacher: item.teacher,
            location: item.location,
          ),
        )
        .toList(growable: false);
    return SkillResult<WeekScheduleOutput>(
      value: WeekScheduleOutput(
        start: range.$1,
        end: range.$2,
        courses: courses,
        dataUpdatedAt: gateway.fetchedAt,
        termsWithoutStartDate: gateway.data!.termsWithoutStartDate,
      ),
      status: gateway.data!.termsWithoutStartDate > 0 || truncated
          ? SkillStatus.partial
          : SkillStatus.success,
      evidence: <SkillEvidence>[
        gatewayEvidence(
          gateway,
          dataType: PersonalDataType.schedule,
          scope: '${range.$1} 至 ${range.$2} 的课表',
        ),
      ],
      warnings: mergeWarnings(
        gateway.warnings,
        <String>[
          if (gateway.data!.termsWithoutStartDate > 0) '部分学期缺少起始日期',
          if (truncated) '课程数量超过上限，仅返回前 $_maximumCourses 条',
        ],
      ),
      containsPersonalData: true,
    );
  }

  static (DateTime, DateTime)? _resolveRange(
    WeekScheduleInput input,
    DateTime now,
  ) {
    if (input.start != null || input.end != null) {
      if (input.start == null || input.end == null) return null;
      final start = _dateOnly(input.start!);
      final end = _dateOnly(input.end!);
      final days = end.difference(start).inDays + 1;
      return days >= 1 && days <= _maximumRangeDays ? (start, end) : null;
    }

    final anchor = _dateOnly(input.weekContaining ?? now);
    final start = anchor.subtract(Duration(days: anchor.weekday - 1));
    return (start, start.add(const Duration(days: 6)));
  }

  static DateTime _dateOnly(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);
}
