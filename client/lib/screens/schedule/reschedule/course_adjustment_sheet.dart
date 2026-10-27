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
  int _weekOffset = 0;
  bool _replaceSameCourse = false;
  String? _saveError;
  late final String _scope;
  late final Meeting? _baseMeeting = _findBaseMeeting();

  @override
  void initState() {
    super.initState();
    _scope = '${widget.provider.sessionKey}:${widget.provider.currentTerm.id}';
    _weekOffset = widget.existingOverride?.weekOffset ?? 0;
    _replaceSameCourse = widget.existingOverride?.replaceSameCourse ?? false;
  }

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
    try {
      final conflict = widget.provider.previewReschedule(
        courseKey: widget.course.courseKey ?? '',
        meetingKey: widget.course.meetingKey ?? '',
        toWeekday: target.weekday,
        toStartSection: target.startSection,
        toEndSection: target.endSection,
        affectedWeeks: _affectedWeeks ?? const <int>{},
        weekOffset: _weekOffset,
        overrideId: widget.existingOverride?.id ?? widget.course.overrideId,
      );
      setState(() {
        _target = target;
        _conflict = conflict;
        _saveError = null;
        _step = 3;
      });
    } catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_scope !=
        '${widget.provider.sessionKey}:${widget.provider.currentTerm.id}') {
      setState(() => _saveError = '账号或学期已切换，请关闭后重新打开课表');
      return;
    }
    final target = _target;
    final weeks = _affectedWeeks;
    if (target == null || weeks == null || weeks.isEmpty) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final course = widget.course;
    final base = _baseMeeting!;
    final snapshot = widget.existingOverride?.sourceSnapshotHash ??
        base.computeSnapshotHash();
    final normalizedRoom = target.newRoom?.trim() ?? '';
    final timeChanged = _weekOffset != 0 ||
        target.weekday != base.weekday ||
        target.startSection != base.startSection ||
        target.endSection != base.endSection;
    final roomChanged = normalizedRoom != (base.room?.trim() ?? '');
    if (!timeChanged && !roomChanged) {
      setState(() => _saving = false);
      setState(() => _saveError = '未检测到任何修改；恢复课程请使用“恢复原安排”');
      return;
    }
    try {
      if (timeChanged) {
        await widget.provider.createRescheduleOverride(
          overrideId: widget.existingOverride?.id ?? course.overrideId,
          courseKey: course.courseKey ?? 'edu:course:${course.name}',
          meetingKey:
              course.meetingKey ?? 'm_${course.weekday}_${course.startSection}',
          affectedWeeks: weeks,
          weekOffset: _weekOffset,
          replaceSameCourse: _replaceSameCourse,
          toWeekday: target.weekday,
          toStartSection: target.startSection,
          toEndSection: target.endSection,
          toRoom: roomChanged ? normalizedRoom : null,
          sourceSnapshotHash: snapshot,
          fromWeekday: base.weekday,
          fromStartSection: base.startSection,
          fromEndSection: base.endSection,
          fromRoom: base.room,
          allowConflict: _conflict?.conflicts
                  .any((c) => !_replaceSameCourse || !c.canReplaceSameCourse) ??
              false,
        );
      } else {
        await widget.provider.createChangeRoomOverride(
          overrideId: widget.existingOverride?.id ?? course.overrideId,
          courseKey: course.courseKey ?? 'edu:course:${course.name}',
          meetingKey:
              course.meetingKey ?? 'm_${course.weekday}_${course.startSection}',
          affectedWeeks: weeks,
          toRoom: normalizedRoom,
          sourceSnapshotHash: snapshot,
          fromRoom: base.room,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => _saveError =
            '保存调整失败，请重试：${error.toString().replaceFirst('Bad state: ', '')}');
      }
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
      canPop: !_saving && _step == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving && _step > 1) setState(() => _step--);
      },
      child: switch (_step) {
        1 => SelectWeeksSheet(
            course: widget.course,
            currentAcademicWeek: widget.currentAcademicWeek,
            totalTeachingWeeks: widget.provider.currentTerm.maxWeek,
            sourceWeeks: base.weeks,
            initialAffectedWeeks:
                _affectedWeeks ?? widget.existingOverride?.affectedWeeks,
            onBack: () => Navigator.pop(context),
            onClose: () => Navigator.pop(context),
            onNext: (weeks) => setState(() {
              _affectedWeeks = weeks;
              _step = 2;
            }),
          ),
        2 => SelectTimeSheet(
            course: widget.course,
            affectedWeeks: _affectedWeeks ?? const <int>{},
            initialWeekOffset: _weekOffset,
            totalTeachingWeeks: widget.provider.currentTerm.maxWeek,
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
            onBack: () => setState(() => _step = 1),
            onClose: () => Navigator.pop(context),
            onNext: (weekday, start, end, room, offset) {
              _weekOffset = offset;
              _goConfirm((
                weekday: weekday,
                startSection: start,
                endSection: end,
                newRoom: room,
              ));
            },
          ),
        _ => ConfirmChangeSheet(
            course: widget.course,
            affectedWeeks: _affectedWeeks ?? const <int>{},
            weekOffset: _weekOffset,
            fromWeekday: base.weekday,
            fromStartSection: base.startSection,
            fromEndSection: base.endSection,
            saving: _saving,
            saveError: _saveError,
            replaceSameCourse: _replaceSameCourse,
            onReplacementChanged: (value) =>
                setState(() => _replaceSameCourse = value),
            toWeekday: _target!.weekday,
            toStartSection: _target!.startSection,
            toEndSection: _target!.endSection,
            toRoom: _target!.newRoom,
            conflictResult: _conflict!,
            onBackToEdit: () => setState(() => _step = 2),
            onBack: () => setState(() => _step = 2),
            onClose: () => Navigator.pop(context),
            onConfirm: _saving ? null : _save,
          ),
      },
    );
  }
}
