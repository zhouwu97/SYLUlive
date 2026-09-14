import '../../models/schedule/course.dart';
import '../../models/schedule/course_source.dart';
import '../../models/schedule/meeting.dart';
import '../../models/schedule/resolved_meeting.dart';
import '../../models/schedule/schedule_override.dart';

/// 课表解析器异常
class ScheduleResolverException implements Exception {
  final String message;
  const ScheduleResolverException(this.message);

  @override
  String toString() => 'ScheduleResolverException: $message';
}

/// 统一课表解析器（ScheduleResolver）
///
/// 任何 UI、桌面小组件、课程详情均必须通过本 Resolver 输出。
/// 输入：BaseSchedule（教务原始） + Overrides（本地调整规则） + ManualCourses（手动课程）
/// 输出：ResolvedMeeting 列表
class ScheduleResolver {
  const ScheduleResolver();

  /// 解析并生成当前学期的最终课表
  List<ResolvedMeeting> resolve({
    required List<Course> baseSchedule,
    required List<ScheduleOverride> overrides,
    List<Course> manualCourses = const <Course>[],
    String? semesterId,
  }) {
    // 1. 过滤指定学期的 Overrides
    final activeOverrides = overrides.where((o) {
      if (semesterId != null && o.semesterId != semesterId) return false;
      return o.isActive;
    }).toList();

    // 2. 校验同一 meetingKey 的活跃 Override 是否存在周次重叠（Section 11 强约束）
    _validateNoDisjointViolations(activeOverrides);

    // 组织 overrides 索引: courseKey -> meetingKey -> list of overrides
    final overrideMap = <String, Map<String, List<ScheduleOverride>>>{};
    for (final ov in activeOverrides) {
      overrideMap
          .putIfAbsent(ov.courseKey, () => <String, List<ScheduleOverride>>{})
          .putIfAbsent(ov.meetingKey, () => <ScheduleOverride>[])
          .add(ov);
    }

    final resolvedList = <ResolvedMeeting>[];

    // 3. 处理教务课表（BaseSchedule）
    for (final course in baseSchedule) {
      if (semesterId != null && course.semesterId != semesterId) continue;

      for (final meeting in course.meetings) {
        final meetingOverrides =
            overrideMap[course.courseKey]?[meeting.meetingKey] ?? const [];

        if (meetingOverrides.isEmpty) {
          // 没有本地调整，原样保留
          if (meeting.weeks.isNotEmpty) {
            resolvedList.add(_createResolved(
              course: course,
              meeting: meeting,
              weeks: meeting.weeks,
              isOverridden: false,
            ));
          }
          continue;
        }

        // 计算所有有效受影响周次
        final allAffectedWeeks = <int>{};
        final overrideWithActualWeeks = <({ScheduleOverride override, Set<int> actualWeeks})>[];

        for (final ov in meetingOverrides) {
          // Section 14: 取 affectedWeeks 与课程实际存在周次的交集
          final actual = ov.affectedWeeks.intersection(meeting.weeks);
          if (actual.isNotEmpty) {
            allAffectedWeeks.addAll(actual);
            overrideWithActualWeeks.add((override: ov, actualWeeks: actual));
          }
        }

        // Section 13: BaseWeeks - affectedWeeks = RemainingWeeks
        final remainingWeeks = meeting.weeks.difference(allAffectedWeeks);
        if (remainingWeeks.isNotEmpty) {
          resolvedList.add(_createResolved(
            course: course,
            meeting: meeting,
            weeks: remainingWeeks,
            isOverridden: false,
          ));
        }

        // 生成调整后的 ResolvedMeeting
        for (final item in overrideWithActualWeeks) {
          final ov = item.override;
          final actualWeeks = item.actualWeeks;

          switch (ov.type) {
            case ScheduleOverrideType.cancel:
              // 停课：不生成该周次的课程块
              break;

            case ScheduleOverrideType.reschedule:
              resolvedList.add(ResolvedMeeting(
                semesterId: course.semesterId,
                courseKey: course.courseKey,
                meetingKey: meeting.meetingKey,
                weekday: ov.toWeekday ?? meeting.weekday,
                startSection: ov.toStartSection ?? meeting.startSection,
                endSection: ov.toEndSection ?? meeting.endSection,
                weeks: actualWeeks,
                room: ov.toRoom ?? meeting.room,
                teacher: meeting.teacher ?? course.teacher,
                source: CourseSource.edu,
                isOverridden: true,
                overrideId: ov.id,
                courseName: course.name,
                courseCode: course.courseCode,
                teachingClassId: course.teachingClassId,
                color: course.color,
                note: meeting.note,
                periodOrder: meeting.periodOrder,
                periodLabel: meeting.periodLabel,
                periodLabels: meeting.periodLabels,
              ));
              break;

            case ScheduleOverrideType.changeRoom:
              resolvedList.add(ResolvedMeeting(
                semesterId: course.semesterId,
                courseKey: course.courseKey,
                meetingKey: meeting.meetingKey,
                weekday: meeting.weekday,
                startSection: meeting.startSection,
                endSection: meeting.endSection,
                weeks: actualWeeks,
                room: ov.toRoom ?? meeting.room,
                teacher: meeting.teacher ?? course.teacher,
                source: CourseSource.edu,
                isOverridden: true,
                overrideId: ov.id,
                courseName: course.name,
                courseCode: course.courseCode,
                teachingClassId: course.teachingClassId,
                color: course.color,
                note: meeting.note,
                periodOrder: meeting.periodOrder,
                periodLabel: meeting.periodLabel,
                periodLabels: meeting.periodLabels,
              ));
              break;
          }
        }
      }
    }

    // 4. 处理手动课程（Section 23: source = manual）
    for (final course in manualCourses) {
      if (semesterId != null && course.semesterId != semesterId) continue;
      for (final meeting in course.meetings) {
        if (meeting.weeks.isEmpty) continue;
        resolvedList.add(_createResolved(
          course: course,
          meeting: meeting,
          weeks: meeting.weeks,
          isOverridden: false,
        ));
      }
    }

    // 5. 冲突检测（Section 20 & 21: 识别时间重叠的课程）
    return _detectConflicts(resolvedList);
  }

  static ResolvedMeeting _createResolved({
    required Course course,
    required Meeting meeting,
    required Set<int> weeks,
    required bool isOverridden,
    String? overrideId,
  }) {
    return ResolvedMeeting(
      semesterId: course.semesterId,
      courseKey: course.courseKey,
      meetingKey: meeting.meetingKey,
      weekday: meeting.weekday,
      startSection: meeting.startSection,
      endSection: meeting.endSection,
      weeks: weeks,
      room: meeting.room,
      teacher: meeting.teacher ?? course.teacher,
      source: course.source,
      isOverridden: isOverridden,
      overrideId: overrideId,
      courseName: course.name,
      courseCode: course.courseCode,
      teachingClassId: course.teachingClassId,
      color: course.color,
      note: meeting.note,
      periodOrder: meeting.periodOrder,
      periodLabel: meeting.periodLabel,
      periodLabels: meeting.periodLabels,
    );
  }

  /// 校验同一 courseKey + meetingKey 的活跃规则 affectedWeeks 是否相交 (Section 11 强约束)
  static void _validateNoDisjointViolations(List<ScheduleOverride> overrides) {
    final group = <String, List<ScheduleOverride>>{};
    for (final ov in overrides) {
      final scopedKey = '${ov.semesterId}|${ov.courseKey}|${ov.meetingKey}';
      group.putIfAbsent(scopedKey, () => []).add(ov);
    }
    for (final entry in group.entries) {
      final list = entry.value;
      if (list.length <= 1) continue;
      for (var i = 0; i < list.length; i++) {
        for (var j = i + 1; j < list.length; j++) {
          final overlap = list[i].affectedWeeks.intersection(list[j].affectedWeeks);
          if (overlap.isNotEmpty) {
            throw ScheduleResolverException(
              '同一上课时间块 (${entry.key}) 存在重叠的本地调整规则: '
              '调整 ${list[i].id} 与 ${list[j].id} 在周次 $overlap 相交',
            );
          }
        }
      }
    }
  }

  /// 冲突检测：标记同一天、相同节次重叠、且周次重合的课程块（记录具体冲突周次）
  static List<ResolvedMeeting> _detectConflicts(List<ResolvedMeeting> list) {
    if (list.length <= 1) return list;

    final conflictWeeksMap = <int, Set<int>>{};
    for (var i = 0; i < list.length; i++) {
      final a = list[i];
      for (var j = i + 1; j < list.length; j++) {
        final b = list[j];
        if (a.weekday != b.weekday) continue;
        // 节次区间是否有重合
        final sectionOverlap =
            a.startSection <= b.endSection && b.startSection <= a.endSection;
        if (!sectionOverlap) continue;

        // 周次集合是否有交集
        final weekOverlap = a.weeks.intersection(b.weeks);
        if (weekOverlap.isNotEmpty) {
          conflictWeeksMap.putIfAbsent(i, () => <int>{}).addAll(weekOverlap);
          conflictWeeksMap.putIfAbsent(j, () => <int>{}).addAll(weekOverlap);
        }
      }
    }

    if (conflictWeeksMap.isEmpty) return list;

    return List<ResolvedMeeting>.generate(list.length, (idx) {
      final cw = conflictWeeksMap[idx];
      if (cw != null && cw.isNotEmpty) {
        final merged = Set<int>.from(list[idx].conflictWeeks)..addAll(cw);
        return list[idx].copyWith(conflictWeeks: merged);
      }
      return list[idx];
    });
  }
}
