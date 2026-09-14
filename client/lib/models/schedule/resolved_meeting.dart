import 'package:flutter/foundation.dart';
import 'course_source.dart';

/// 最终解析后的课程时间块（ResolvedMeeting）
///
/// 任何 UI、桌面小组件、冲突检测均消费 [ResolvedMeeting]。
/// 由 [ScheduleResolver] 基于 BaseSchedule + ScheduleOverride + 手动课程计算生成。
class ResolvedMeeting {
  final String semesterId;
  final String courseKey;
  final String meetingKey;

  final int weekday;
  final int startSection;
  final int endSection;

  final Set<int> weeks;

  final String? room;
  final String? teacher;

  final CourseSource source;

  final bool isOverridden;
  final String? overrideId;

  final Set<int> conflictWeeks;
  final bool? _legacyHasConflict;

  bool hasConflictAtWeek(int week) => conflictWeeks.contains(week);
  bool get hasConflict => _legacyHasConflict ?? conflictWeeks.isNotEmpty;

  // 展示与兼容字段
  final String courseName;
  final String? courseCode;
  final String? teachingClassId;
  final String color;
  final String? note;
  final int? periodOrder;
  final String? periodLabel;
  final List<String> periodLabels;

  const ResolvedMeeting({
    required this.semesterId,
    required this.courseKey,
    required this.meetingKey,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.weeks,
    this.room,
    this.teacher,
    required this.source,
    this.isOverridden = false,
    this.overrideId,
    this.conflictWeeks = const <int>{},
    bool? hasConflict,
    required this.courseName,
    this.courseCode,
    this.teachingClassId,
    this.color = '#6366F1',
    this.note,
    this.periodOrder,
    this.periodLabel,
    this.periodLabels = const <String>[],
  }) : _legacyHasConflict = hasConflict;

  int get span => endSection - startSection + 1;

  ResolvedMeeting copyWith({
    String? semesterId,
    String? courseKey,
    String? meetingKey,
    int? weekday,
    int? startSection,
    int? endSection,
    Set<int>? weeks,
    String? room,
    String? teacher,
    CourseSource? source,
    bool? isOverridden,
    String? overrideId,
    Set<int>? conflictWeeks,
    bool? hasConflict,
    String? courseName,
    String? courseCode,
    String? teachingClassId,
    String? color,
    String? note,
    int? periodOrder,
    String? periodLabel,
    List<String>? periodLabels,
  }) {
    final effectiveConflictWeeks = conflictWeeks ??
        (hasConflict == false
            ? const <int>{}
            : (hasConflict == true && this.conflictWeeks.isEmpty
                ? (weeks ?? this.weeks)
                : this.conflictWeeks));

    return ResolvedMeeting(
      semesterId: semesterId ?? this.semesterId,
      courseKey: courseKey ?? this.courseKey,
      meetingKey: meetingKey ?? this.meetingKey,
      weekday: weekday ?? this.weekday,
      startSection: startSection ?? this.startSection,
      endSection: endSection ?? this.endSection,
      weeks: weeks ?? this.weeks,
      room: room ?? this.room,
      teacher: teacher ?? this.teacher,
      source: source ?? this.source,
      isOverridden: isOverridden ?? this.isOverridden,
      overrideId: overrideId ?? this.overrideId,
      conflictWeeks: effectiveConflictWeeks,
      hasConflict: hasConflict,
      courseName: courseName ?? this.courseName,
      courseCode: courseCode ?? this.courseCode,
      teachingClassId: teachingClassId ?? this.teachingClassId,
      color: color ?? this.color,
      note: note ?? this.note,
      periodOrder: periodOrder ?? this.periodOrder,
      periodLabel: periodLabel ?? this.periodLabel,
      periodLabels: periodLabels ?? this.periodLabels,
    );
  }

  /// 转换为全局兼容的 CourseBlock 结构供现有页面与小组件消费
  Map<String, dynamic> toCourseBlockMap({int? deterministicId}) {
    final sortedWeeks = weeks.toList()..sort();
    final sortedConflictWeeks = conflictWeeks.toList()..sort();
    return {
      'id': deterministicId ?? (source == CourseSource.manual ? -1 : 1),
      'course_code': courseCode ?? '',
      'name': courseName,
      'teacher': teacher,
      'location': room,
      'color': color,
      'weekday': weekday,
      'start_section': startSection,
      'end_section': endSection,
      'weeks': sortedWeeks,
      'note': note,
      'period_order': periodOrder,
      'period_label': periodLabel,
      'period_labels': periodLabels,
      'is_overridden': isOverridden,
      'override_id': overrideId,
      'has_conflict': hasConflict,
      'conflict_weeks': sortedConflictWeeks,
      'course_key': courseKey,
      'meeting_key': meetingKey,
      'teaching_class_id': teachingClassId,
      'source': source.name,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedMeeting &&
          runtimeType == other.runtimeType &&
          semesterId == other.semesterId &&
          courseKey == other.courseKey &&
          meetingKey == other.meetingKey &&
          weekday == other.weekday &&
          startSection == other.startSection &&
          endSection == other.endSection &&
          setEquals(weeks, other.weeks) &&
          room == other.room &&
          teacher == other.teacher &&
          source == other.source &&
          isOverridden == other.isOverridden &&
          overrideId == other.overrideId &&
          setEquals(conflictWeeks, other.conflictWeeks) &&
          hasConflict == other.hasConflict;

  @override
  int get hashCode =>
      semesterId.hashCode ^
      courseKey.hashCode ^
      meetingKey.hashCode ^
      weekday.hashCode ^
      startSection.hashCode ^
      endSection.hashCode;
}
