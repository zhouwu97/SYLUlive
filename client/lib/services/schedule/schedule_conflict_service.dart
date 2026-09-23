import '../../models/schedule/resolved_meeting.dart';

/// 课程冲突详细信息
class ScheduleConflictInfo {
  final String existingCourseName;
  final String? existingTeacher;
  final String? existingRoom;
  final int weekday;
  final int startSection;
  final int endSection;
  final Set<int> conflictingWeeks;

  const ScheduleConflictInfo({
    required this.existingCourseName,
    this.existingTeacher,
    this.existingRoom,
    required this.weekday,
    required this.startSection,
    required this.endSection,
    required this.conflictingWeeks,
  });
}

/// 冲突检查结果
class ScheduleConflictCheckResult {
  final bool hasConflict;
  final List<ScheduleConflictInfo> conflicts;

  const ScheduleConflictCheckResult({
    required this.hasConflict,
    this.conflicts = const <ScheduleConflictInfo>[],
  });

  static const noConflict = ScheduleConflictCheckResult(hasConflict: false);
}

/// 课程时间冲突检测服务（ScheduleConflictService）
///
/// 在三步调课第三步及保存前，自动检测目标时间与已有课程的重叠情况
class ScheduleConflictService {
  const ScheduleConflictService();

  /// 检查拟调整的目标时间是否与现有课表产生冲突
  ScheduleConflictCheckResult check({
    required List<ResolvedMeeting> currentResolved,
    required String targetCourseKey,
    required String targetMeetingKey,
    required int targetWeekday,
    required int targetStartSection,
    required int targetEndSection,
    required Set<int> targetWeeks,
    String? editingOverrideId,
  }) {
    final conflicts = <ScheduleConflictInfo>[];

    for (final resolved in currentResolved) {
      // 当前调整的同一 meeting 即使仍显示原时间，也不能把自己当作冲突。
      if (resolved.courseKey == targetCourseKey &&
          resolved.meetingKey == targetMeetingKey) {
        continue;
      }

      // 排除当前正在调整的源时间块本身在旧时间上的出现（或者自身就是正在编辑的 override）
      if (editingOverrideId != null &&
          resolved.overrideId == editingOverrideId) {
        continue;
      }

      // 检查星期
      if (resolved.weekday != targetWeekday) continue;

      // 检查节次重叠
      final sectionOverlap = resolved.startSection <= targetEndSection &&
          targetStartSection <= resolved.endSection;
      if (!sectionOverlap) continue;

      // 检查周次交集
      final weekOverlap = resolved.weeks.intersection(targetWeeks);
      if (weekOverlap.isEmpty) continue;

      conflicts.add(ScheduleConflictInfo(
        existingCourseName: resolved.courseName,
        existingTeacher: resolved.teacher,
        existingRoom: resolved.room,
        weekday: resolved.weekday,
        startSection: resolved.startSection,
        endSection: resolved.endSection,
        conflictingWeeks: weekOverlap,
      ));
    }

    return ScheduleConflictCheckResult(
      hasConflict: conflicts.isNotEmpty,
      conflicts: conflicts,
    );
  }
}
