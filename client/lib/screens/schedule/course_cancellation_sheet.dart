import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/schedule/meeting.dart';
import '../../models/schedule/schedule_override.dart';
import '../../providers/course_schedule_provider.dart';
import '../../theme/app_theme_tokens.dart';
import '../../utils/week_formatter.dart';
import '../../widgets/app_card.dart';
import 'reschedule/select_weeks_sheet.dart';

class CourseCancellationSheet extends StatefulWidget {
  const CourseCancellationSheet(
      {super.key,
      required this.course,
      required this.provider,
      required this.currentAcademicWeek,
      this.existingOverride});

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
          builder: (_) => CourseCancellationSheet(
              course: course,
              provider: provider,
              currentAcademicWeek: currentAcademicWeek,
              existingOverride: existingOverride));

  @override
  State<CourseCancellationSheet> createState() =>
      _CourseCancellationSheetState();
}

class _CourseCancellationSheetState extends State<CourseCancellationSheet> {
  bool _saving = false;
  String? _error;
  late final int _generation;
  late final Meeting? _base = widget.provider.baseSchedule
      .where((c) => c.courseKey == widget.course.courseKey)
      .expand((c) => c.meetings)
      .where((m) => m.meetingKey == widget.course.meetingKey)
      .firstOrNull;

  @override
  void initState() {
    super.initState();
    _generation = widget.provider.contextGeneration;
  }

  Future<void> _delete(Set<int> visibleWeeks) async {
    if (_saving) return;
    if (_generation != widget.provider.contextGeneration) {
      setState(() => _error = '账号或学期已切换，请关闭后重新打开课表');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final offset = widget.existingOverride?.weekOffset ?? 0;
    try {
      await widget.provider.createCancelOverride(
          courseKey: widget.course.courseKey!,
          meetingKey: widget.course.meetingKey!,
          affectedWeeks: visibleWeeks.map((week) => week - offset).toSet(),
          sourceSnapshotHash: _base!.computeSnapshotHash(),
          overrideId: widget.existingOverride?.id);
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            '删除失败，请重试：${error.toString().replaceFirst('Bad state: ', '')}');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_base == null) {
      return SafeArea(
          child: AppCardSurface(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('无法定位该课程的教务原始安排，请先重新同步课表后再删除。'),
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ]),
      ));
    }
    return PopScope(
        canPop: !_saving,
        child: SelectWeeksSheet(
          course: widget.course,
          currentAcademicWeek: widget.currentAcademicWeek,
          totalTeachingWeeks: widget.provider.currentTerm.maxWeek,
          sourceWeeks: widget.course.weeks.toSet(),
          initialAffectedWeeks: widget.course.weeks.isEmpty ||
                  widget.course.weeks.contains(widget.currentAcademicWeek)
              ? {widget.currentAcademicWeek}
              : null,
          deleting: true,
          saving: _saving,
          saveError: _error,
          onNext: _delete,
        ));
  }
}

class CancelledCoursesSheet extends StatefulWidget {
  const CancelledCoursesSheet({super.key});

  static Future<void> show(BuildContext context,
          {required CourseScheduleProvider provider}) =>
      showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          isDismissible: false,
          enableDrag: false,
          backgroundColor: Colors.transparent,
          builder: (_) => ChangeNotifierProvider.value(
              value: provider, child: const CancelledCoursesSheet()));

  @override
  State<CancelledCoursesSheet> createState() => _CancelledCoursesSheetState();
}

class _CancelledCoursesSheetState extends State<CancelledCoursesSheet> {
  String? _busyId;
  String? _error;
  late int _generation;

  @override
  void initState() {
    super.initState();
    _generation = context.read<CourseScheduleProvider>().contextGeneration;
  }

  Future<void> _act(CourseScheduleProvider provider, ScheduleOverride rule,
      {bool confirm = false}) async {
    if (_busyId != null) return;
    if (_generation != provider.contextGeneration) {
      setState(() => _error = '账号或学期已切换，请关闭后重新打开课表');
      return;
    }
    setState(() {
      _busyId = rule.id;
      _error = null;
    });
    try {
      if (confirm) {
        await provider.confirmNeedsReviewOverride(rule.id);
      } else {
        await provider.restoreBaseMeeting(rule.id);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            '操作失败，请重试：${error.toString().replaceFirst('Bad state: ', '')}');
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CourseScheduleProvider>();
    final tokens = AppThemeTokens.of(context);
    final scopeChanged = _generation != provider.contextGeneration;
    final loading =
        provider.sessionPhase == ScheduleSessionPhase.openingStore ||
            provider.sessionPhase == ScheduleSessionPhase.restoringCache;
    final failed = provider.sessionPhase == ScheduleSessionPhase.restoreFailed;
    final rules = (scopeChanged ? <ScheduleOverride>[] : provider.overrides)
        .where((rule) => rule.type == ScheduleOverrideType.cancel)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return PopScope(
        canPop: _busyId == null,
        child: SafeArea(
          top: false,
          child: AppCardSurface(
            surfaceOpacity: appTextSheetSurfaceOpacity(context),
            decoration: BoxDecoration(
                color: tokens.surface,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24))),
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .8),
              child: SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text('已删除课程',
                            style: Theme.of(context).textTheme.titleLarge)),
                    IconButton(
                        tooltip: '关闭',
                        onPressed: _busyId != null
                            ? null
                            : () => Navigator.pop(context),
                        icon: const Icon(Icons.close)),
                  ]),
                  const Text('恢复后使用学校教务原安排，其他周次的本地调整继续保留。合并课程按原安排分别记录。'),
                  const SizedBox(height: 16),
                  if (scopeChanged)
                    const Text('账号或学期已切换，请关闭后重新打开课表')
                  else if (loading)
                    const Center(child: CircularProgressIndicator())
                  else if (failed) ...[
                    Text(provider.errorMessage ?? '本机课表读取失败'),
                    TextButton(
                        onPressed: () async {
                          final pending = provider.retryLocalRestore();
                          setState(
                              () => _generation = provider.contextGeneration);
                          await pending;
                        },
                        child: const Text('重试读取')),
                  ] else if (rules.isEmpty)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Center(child: Text('暂无本地删除记录'))),
                  if (!loading && !failed)
                    for (final rule in rules)
                      _buildRule(context, provider, rule),
                  if (_error != null)
                    Semantics(
                        liveRegion: true,
                        child: Text(_error!,
                            style: TextStyle(color: tokens.error))),
                ],
              )),
            ),
          ),
        ));
  }

  Widget _buildRule(BuildContext context, CourseScheduleProvider provider,
      ScheduleOverride rule) {
    final course = provider.baseSchedule
        .where((c) => c.courseKey == rule.courseKey)
        .firstOrNull;
    final meeting = course?.meetings
        .where((m) => m.meetingKey == rule.meetingKey)
        .firstOrNull;
    final needsReview = rule.status == ScheduleOverrideStatus.needsReview;
    final visibleWeeks = rule.targetWeeksFor(rule.affectedWeeks).toList()
      ..sort();
    return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppCardDivider(),
            const SizedBox(height: 12),
            Text(course?.name ?? '原课程已不存在',
                style: Theme.of(context).textTheme.titleMedium),
            Text(
                '已删除：${WeekFormatter.format(visibleWeeks, prefixWithDi: true)}'),
            if (meeting != null)
              Text(
                  '教务原安排：${WeekFormatter.format(rule.affectedWeeks.toList(), prefixWithDi: true)} '
                  '周${const [
                '一',
                '二',
                '三',
                '四',
                '五',
                '六',
                '日'
              ][meeting.weekday - 1]} '
                  '第${meeting.startSection}-${meeting.endSection}节'),
            if (needsReview) const Text('学校课表已变化，此删除暂未生效，请重新确认或恢复原安排。'),
            if (meeting == null) const Text('学校已不再提供这次上课安排，可以移除本地记录。'),
            Wrap(spacing: 8, children: [
              if (needsReview)
                TextButton(
                    onPressed: _busyId != null
                        ? null
                        : () => _act(provider, rule, confirm: true),
                    child: const Text('重新确认删除')),
              OutlinedButton(
                  onPressed:
                      _busyId != null ? null : () => _act(provider, rule),
                  child: Text(_busyId == rule.id
                      ? '正在处理…'
                      : meeting == null
                          ? '移除记录'
                          : '恢复教务原安排')),
            ]),
          ],
        ));
  }
}
