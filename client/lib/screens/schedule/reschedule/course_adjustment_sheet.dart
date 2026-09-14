import 'package:flutter/material.dart';
import '../../../models/schedule/schedule_override.dart';
import '../../../providers/course_schedule_provider.dart';
import '../../../models/schedule/meeting.dart';
import '../../../services/schedule/schedule_conflict_service.dart';
import 'select_weeks_sheet.dart';
import 'select_time_sheet.dart';
import 'confirm_change_sheet.dart';

/// 调课唯一入口：一个 BottomSheet 内维护三步草稿，避免多个 Route 之间丢状态。
class CourseAdjustmentSheet extends StatefulWidget {
  const CourseAdjustmentSheet({
    super.key,
    required this.course,
    required this.provider,
    required this.currentAcademicWeek,
    this.existingOverride,
  });

  final CourseBlock course;
  final CourseScheduleProvider provider;
  final int currentAcademicWeek;
  final ScheduleOverride? existingOverride;

  static Future<bool?> show(
    BuildContext context, {
    required CourseBlock course,
    required CourseScheduleProvider provider,
    required int currentAcademicWeek,
    ScheduleOverride? existingOverride,
  }) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: Colors.transparent,
        builder: (_) => CourseAdjustmentSheet(
          course: course,
          provider: provider,
          currentAcademicWeek: currentAcademicWeek,
          existingOverride: existingOverride,
        ),
      );

  @override
  State<CourseAdjustmentSheet> createState() => _CourseAdjustmentSheetState();
}

class _CourseAdjustmentSheetState extends State<CourseAdjustmentSheet> {
  int _step = 1;
  Set<int>? _affectedWeeks;
  ({int weekday, int startSection, int endSection, String? newRoom})? _target;
  ScheduleConflictCheckResult? _conflict;
  bool _saving = false;
  late final Meeting? _baseMeeting = _findBaseMeeting();

  Meeting? _findBaseMeeting() {
    final courseKey = widget.course.courseKey;
    final meetingKey = widget.course.meetingKey;
    if (courseKey == null || meetingKey == null) return null;
    for (final course in widget.provider.baseSchedule) {
      if (course.courseKey != courseKey) continue;
      for (final meeting in course.meetings) {
        if (meeting.meetingKey == meetingKey) return meeting;
      }
    }
    return null;
  }

  void _goConfirm(
      ({
        int weekday,
        int startSection,
        int endSection,
        String? newRoom
      }) target) {
    final conflict = const ScheduleConflictService().check(
      currentResolved: widget.provider.resolvedMeetings,
      targetCourseKey: widget.course.courseKey ?? '',
      targetMeetingKey: widget.course.meetingKey ?? '',
      targetWeekday: target.weekday,
      targetStartSection: target.startSection,
      targetEndSection: target.endSection,
      targetWeeks: _affectedWeeks ?? const <int>{},
      editingOverrideId:
          widget.existingOverride?.id ?? widget.course.overrideId,
    );
    setState(() {
      _target = target;
      _conflict = conflict;
      _step = 3;
    });
  }

  Future<void> _save() async {
    final target = _target;
    final weeks = _affectedWeeks;
    if (target == null || weeks == null || weeks.isEmpty) return;
    setState(() => _saving = true);
    final course = widget.course;
    final base = _baseMeeting!;
    final snapshot = widget.existingOverride?.sourceSnapshotHash ??
        base.computeSnapshotHash();
    try {
      await widget.provider.createRescheduleOverride(
        overrideId: widget.existingOverride?.id ?? course.overrideId,
        courseKey: course.courseKey ?? 'edu:course:${course.name}',
        meetingKey:
            course.meetingKey ?? 'm_${course.weekday}_${course.startSection}',
        affectedWeeks: weeks,
        toWeekday: target.weekday,
        toStartSection: target.startSection,
        toEndSection: target.endSection,
        toRoom: target.newRoom,
        sourceSnapshotHash: snapshot,
        fromWeekday: base.weekday,
        fromStartSection: base.startSection,
        fromEndSection: base.endSection,
        fromRoom: base.room,
        allowConflict: _conflict?.hasConflict ?? false,
      );
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_baseMeeting == null) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('无法定位该课程的教务原始安排，请先重新同步课表后再调整。'),
            const SizedBox(height: 16),
            FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭')),
          ]),
        ),
      );
    }
    final base = _baseMeeting!;
    return PopScope(
      canPop: _step == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _step > 1) setState(() => _step--);
      },
      child: switch (_step) {
        1 => SelectWeeksSheet(
            course: widget.course,
            currentAcademicWeek: widget.currentAcademicWeek,
            totalTeachingWeeks: widget.provider.currentTerm.maxWeek,
            sourceWeeks: base.weeks,
            initialAffectedWeeks: widget.existingOverride?.affectedWeeks,
            onNext: (weeks) => setState(() {
              _affectedWeeks = weeks;
              _step = 2;
            }),
          ),
        2 => SelectTimeSheet(
            course: widget.course,
            affectedWeeks: _affectedWeeks ?? const <int>{},
            initialWeekday: _target?.weekday ??
                widget.existingOverride?.toWeekday ??
                base.weekday,
            initialStartSection: _target?.startSection ??
                widget.existingOverride?.toStartSection ??
                base.startSection,
            initialEndSection: _target?.endSection ??
                widget.existingOverride?.toEndSection ??
                base.endSection,
            initialRoom: _target?.newRoom ??
                widget.existingOverride?.toRoom ??
                base.room,
            onNext: (weekday, start, end, room) => _goConfirm((
              weekday: weekday,
              startSection: start,
              endSection: end,
              newRoom: room,
            )),
          ),
        _ => ConfirmChangeSheet(
            course: widget.course,
            affectedWeeks: _affectedWeeks ?? const <int>{},
            toWeekday: _target!.weekday,
            toStartSection: _target!.startSection,
            toEndSection: _target!.endSection,
            toRoom: _target!.newRoom,
            conflictResult: _conflict!,
            onBackToEdit: () => setState(() => _step = 2),
            onConfirm: _saving ? () {} : _save,
          ),
      },
    );
  }
}
