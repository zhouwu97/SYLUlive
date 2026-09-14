import '../../models/schedule/course.dart';
import '../../models/schedule/course_source.dart';
import '../../models/schedule/meeting.dart';
import '../../models/schedule/schedule_override.dart';

/// 教务课表对齐结果
class MeetingReconcileResult {
  final List<Course> reconciledCourses;
  final List<ScheduleOverride> updatedOverrides;
  final List<ScheduleOverride> orphanedOverrides;
  final List<ScheduleOverride> needsReviewOverrides;

  const MeetingReconcileResult({
    required this.reconciledCourses,
    required this.updatedOverrides,
    required this.orphanedOverrides,
    required this.needsReviewOverrides,
  });
}

/// 教务课表对齐器（MeetingReconciler）
///
/// 每次教务重新同步后，解决跨同步 MeetingKey 稳定继承与 Override 源快照校验。
/// 避免因无序生成 ID 导致本地调整规则失效或误伤其他时间块。
class MeetingReconciler {
  const MeetingReconciler();

  /// 对齐新教务数据与旧课表结构
  MeetingReconcileResult reconcile({
    required List<Course> oldBaseSchedule,
    required List<Course> newEduCourses,
    required List<ScheduleOverride> existingOverrides,
    required String semesterId,
  }) {
    final reconciledCourses = <Course>[];
    final allReconciledMeetings = <String, Meeting>{}; // meetingKey -> Meeting

    for (final newCourse in newEduCourses) {
      // 1. 寻找匹配的旧课程
      final oldCourse = _findMatchingOldCourse(newCourse, oldBaseSchedule);

      if (oldCourse == null) {
        // 全新课程，为各个 meeting 生成稳定 key
        final meetingsWithKey = newCourse.meetings.map((m) {
          final key = m.meetingKey.isNotEmpty
              ? m.meetingKey
              : _generateMeetingKey(newCourse.courseKey, m);
          final meeting = m.copyWith(meetingKey: key);
          allReconciledMeetings[key] = meeting;
          return meeting;
        }).toList();

        reconciledCourses.add(newCourse.copyWith(meetings: meetingsWithKey));
        continue;
      }

      // 2. 匹配并继承旧课程的 MeetingKey
      final usedOldMeetingKeys = <String>{};
      final reconciledMeetings = <Meeting>[];

      for (final newMeeting in newCourse.meetings) {
        final bestOldMeeting = _findBestMatchingOldMeeting(
          newMeeting,
          oldCourse.meetings,
          usedOldMeetingKeys,
        );

        if (bestOldMeeting != null) {
          usedOldMeetingKeys.add(bestOldMeeting.meetingKey);
          final inherited = newMeeting.copyWith(
            meetingKey: bestOldMeeting.meetingKey,
          );
          reconciledMeetings.add(inherited);
          allReconciledMeetings[bestOldMeeting.meetingKey] = inherited;
        } else {
          final key = newMeeting.meetingKey.isNotEmpty
              ? newMeeting.meetingKey
              : _generateMeetingKey(newCourse.courseKey, newMeeting);
          final meeting = newMeeting.copyWith(meetingKey: key);
          reconciledMeetings.add(meeting);
          allReconciledMeetings[key] = meeting;
        }
      }

      reconciledCourses.add(newCourse.copyWith(meetings: reconciledMeetings));
    }

    // 3. 校验并更新现有的 ScheduleOverride（Section 10: SourceSnapshotHash 校验）
    final updatedOverrides = <ScheduleOverride>[];
    final orphanedOverrides = <ScheduleOverride>[];
    final needsReviewOverrides = <ScheduleOverride>[];

    for (final ov in existingOverrides) {
      if (ov.semesterId != semesterId) {
        // 不属于当前学期的规则直接原样保留，不参与本轮对齐
        updatedOverrides.add(ov);
        continue;
      }

      final matchedMeeting = allReconciledMeetings[ov.meetingKey];

      if (matchedMeeting == null) {
        // 无法重新关联到对应 Meeting（例如学校已取消该课程安排）
        final orphaned = ov.copyWith(
          status: ScheduleOverrideStatus.orphaned,
          updatedAt: DateTime.now(),
        );
        updatedOverrides.add(orphaned);
        orphanedOverrides.add(orphaned);
        continue;
      }

      // 检查原 Meeting 是否发生了关键变化
      final currentHash = matchedMeeting.computeSnapshotHash();
      if (ov.sourceSnapshotHash.isNotEmpty &&
          ov.sourceSnapshotHash != currentHash) {
        // 源数据发生变化，标记为 needsReview
        final review = ov.copyWith(
          status: ScheduleOverrideStatus.needsReview,
          updatedAt: DateTime.now(),
        );
        updatedOverrides.add(review);
        needsReviewOverrides.add(review);
      } else {
        // 源数据完全一致或已重新对齐，保留正常状态
        if (ov.status == ScheduleOverrideStatus.orphaned ||
            ov.status == ScheduleOverrideStatus.needsReview) {
          final restored = ov.copyWith(
            status: ScheduleOverrideStatus.active,
            updatedAt: DateTime.now(),
          );
          updatedOverrides.add(restored);
        } else {
          updatedOverrides.add(ov);
        }
      }
    }

    return MeetingReconcileResult(
      reconciledCourses: reconciledCourses,
      updatedOverrides: updatedOverrides,
      orphanedOverrides: orphanedOverrides,
      needsReviewOverrides: needsReviewOverrides,
    );
  }

  static Course? _findMatchingOldCourse(Course newCourse, List<Course> oldList) {
    // 筛除不同学期或非教务来源的课程，避免跨学期或跨来源错配
    final candidates = oldList.where((old) {
      if (old.source != CourseSource.edu) return false;
      if (old.semesterId.isNotEmpty &&
          newCourse.semesterId.isNotEmpty &&
          old.semesterId != newCourse.semesterId) {
        return false;
      }
      return true;
    }).toList();

    // 1. 优先通过教学班 ID + 课程代码双重匹配
    if (newCourse.teachingClassId != null &&
        newCourse.teachingClassId!.isNotEmpty &&
        newCourse.courseCode != null &&
        newCourse.courseCode!.isNotEmpty) {
      for (final old in candidates) {
        if (old.teachingClassId == newCourse.teachingClassId &&
            old.courseCode == newCourse.courseCode) {
          return old;
        }
      }
    }

    // 2. 教学班 ID 单独匹配
    if (newCourse.teachingClassId != null &&
        newCourse.teachingClassId!.isNotEmpty) {
      for (final old in candidates) {
        if (old.teachingClassId == newCourse.teachingClassId) return old;
      }
    }

    // 3. 课程代码匹配
    if (newCourse.courseCode != null && newCourse.courseCode!.isNotEmpty) {
      final codeMatches =
          candidates.where((o) => o.courseCode == newCourse.courseCode).toList();
      if (codeMatches.length == 1) return codeMatches.first;
      if (codeMatches.isNotEmpty) {
        for (final m in codeMatches) {
          if (m.name == newCourse.name) return m;
        }
      }
    }

    // 4. 课程名称 + 教师
    for (final old in candidates) {
      if (old.name == newCourse.name && old.teacher == newCourse.teacher) {
        return old;
      }
    }

    // 5. 纯课程名称（唯一时）
    final nameMatches = candidates.where((o) => o.name == newCourse.name).toList();
    if (nameMatches.length == 1) return nameMatches.first;

    return null;
  }

  static Meeting? _findBestMatchingOldMeeting(
    Meeting newMeeting,
    List<Meeting> oldMeetings,
    Set<String> usedKeys,
  ) {
    Meeting? bestMatch;
    var bestScore = 0;

    for (final old in oldMeetings) {
      if (usedKeys.contains(old.meetingKey)) continue;

      var score = 0;

      // 星期完全匹配
      if (old.weekday == newMeeting.weekday) score += 30;

      // 节次完全匹配
      if (old.startSection == newMeeting.startSection &&
          old.endSection == newMeeting.endSection) {
        score += 30;
      } else if (old.startSection <= newMeeting.endSection &&
          newMeeting.startSection <= old.endSection) {
        score += 15; // 节次重叠
      }

      // 周次交集重合度
      final intersection = old.weeks.intersection(newMeeting.weeks);
      final union = old.weeks.union(newMeeting.weeks);
      if (union.isNotEmpty) {
        final jaccard = intersection.length / union.length;
        score += (jaccard * 25).round();
      }

      // 教室匹配
      if (old.room != null &&
          newMeeting.room != null &&
          old.room!.trim() == newMeeting.room!.trim() &&
          old.room!.trim().isNotEmpty) {
        score += 15;
      }

      if (score > bestScore) {
        bestScore = score;
        bestMatch = old;
      }
    }

    // 仅在高置信度（>= 55分）时复用旧 meetingKey；避免强行猜测导致误伤
    if (bestScore >= 55) {
      return bestMatch;
    }
    return null;
  }

  static String _generateMeetingKey(String courseKey, Meeting meeting) {
    final sortedWeeks = meeting.weeks.toList()..sort();
    return '$courseKey:m:w${meeting.weekday}:s${meeting.startSection}-${meeting.endSection}:wks[${sortedWeeks.join(',')}]';
  }
}
