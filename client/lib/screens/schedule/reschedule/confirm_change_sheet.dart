import 'package:flutter/material.dart';
import '../../../providers/course_schedule_provider.dart';
import '../../../services/schedule/schedule_conflict_service.dart';
import '../../../theme/app_theme_tokens.dart';
import '../../../theme/app_radius.dart';
import '../../../utils/week_formatter.dart';

/// 调课第三步：确认源周次、目标周次、合并方式及真实冲突。
class ConfirmChangeSheet extends StatelessWidget {
  final CourseBlock course;
  final Set<int> affectedWeeks;
  final int weekOffset;
  final int toWeekday;
  final int toStartSection;
  final int toEndSection;
  final String? toRoom;
  final ScheduleConflictCheckResult conflictResult;
  final VoidCallback? onConfirm;
  final VoidCallback onBackToEdit;
  final VoidCallback? onBack;
  final VoidCallback? onClose;
  final bool replaceSameCourse;
  final ValueChanged<bool>? onReplacementChanged;
  final bool saving;
  final String? saveError;
  final int? fromWeekday;
  final int? fromStartSection;
  final int? fromEndSection;

  const ConfirmChangeSheet({
    super.key,
    required this.course,
    required this.affectedWeeks,
    required this.toWeekday,
    required this.toStartSection,
    required this.toEndSection,
    this.toRoom,
    required this.conflictResult,
    required this.onConfirm,
    required this.onBackToEdit,
    this.onBack,
    this.onClose,
    this.weekOffset = 0,
    this.replaceSameCourse = false,
    this.onReplacementChanged,
    this.saving = false,
    this.saveError,
    this.fromWeekday,
    this.fromStartSection,
    this.fromEndSection,
  });

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final text = Theme.of(context).textTheme;
    final sourceWeeks = affectedWeeks.toList()..sort();
    final targetWeeks = sourceWeeks.map((w) => w + weekOffset).toList();
    final matches =
        conflictResult.conflicts.where((c) => c.canReplaceSameCourse).toList();
    final conflicts = conflictResult.conflicts
        .where((c) => !replaceSameCourse || !c.canReplaceSameCourse)
        .toList();
    final hasConflict = conflicts.isNotEmpty ||
        (conflictResult.hasConflict && conflictResult.conflicts.isEmpty);

    Widget arrangement(
            String label, List<int> weeks, int weekday, int start, int end) =>
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: text.labelLarge?.copyWith(color: tokens.textSecondary)),
          const SizedBox(height: 4),
          Text(WeekFormatter.format(weeks, prefixWithDi: true),
              style: text.bodyMedium),
          Text('周${_weekdays[weekday - 1]} 第$start-$end节',
              style: text.bodyMedium),
        ]);

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
        decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.sheet))),
        child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              IconButton(
                  tooltip: '返回修改',
                  onPressed: saving ? null : onBack ?? onBackToEdit,
                  icon: const Icon(Icons.arrow_back)),
              Expanded(child: Text('确认修改 (3/3)', style: text.titleMedium)),
              IconButton(
                  tooltip: '关闭调课',
                  onPressed:
                      saving ? null : onClose ?? () => Navigator.pop(context),
                  icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 12),
            Text(course.name,
                style: text.titleSmall?.copyWith(color: tokens.primary)),
            const SizedBox(height: 16),
            arrangement(
                '原时间',
                sourceWeeks,
                fromWeekday ?? course.weekday,
                fromStartSection ?? course.startSection,
                fromEndSection ?? course.endSection),
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Icon(Icons.arrow_downward)),
            arrangement(
                '新时间', targetWeeks, toWeekday, toStartSection, toEndSection),
            if (toRoom?.isNotEmpty == true)
              Text('教室：$toRoom', style: text.bodyMedium),
            const SizedBox(height: 12),
            Text('原周次的所选安排将移除，其他周次按原安排显示。',
                style: text.bodySmall?.copyWith(color: tokens.textSecondary)),
            if (matches.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('目标时间已有同一课程', style: text.titleSmall),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: replaceSameCourse,
                onChanged: saving || onReplacementChanged == null
                    ? null
                    : (value) => onReplacementChanged!(value ?? false),
                title: const Text('合并同一课程的原安排'),
                subtitle: const Text('仅合并同一课程且时间完全相同的原安排，目标位置显示一次；恢复原安排时一并还原。'),
              ),
            ],
            const SizedBox(height: 16),
            Row(children: [
              Icon(
                  hasConflict
                      ? Icons.warning_amber_rounded
                      : Icons.check_circle_outline,
                  color: hasConflict ? tokens.warning : tokens.success),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(hasConflict ? '发现时间冲突' : '未发现课程冲突',
                      style: text.titleSmall?.copyWith(
                          color:
                              hasConflict ? tokens.warning : tokens.success))),
            ]),
            for (final conflict in conflicts)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      '${WeekFormatter.format(conflict.conflictingWeeks.toList(), prefixWithDi: true)} '
                      '周${_weekdays[conflict.weekday - 1]} 第${conflict.startSection}-${conflict.endSection}节 '
                      '已有课程：${conflict.existingCourseName}',
                      style: text.bodySmall)),
            if (hasConflict)
              Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('继续保存后，重叠的课程会同时保留并标注冲突。', style: text.bodySmall)),
            if (saveError != null)
              Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Semantics(
                      liveRegion: true,
                      child: Text(saveError!,
                          style:
                              text.bodyMedium?.copyWith(color: tokens.error)))),
            const SizedBox(height: 20),
            SizedBox(
                width: double.infinity,
                child: FilledButton(
                    style: FilledButton.styleFrom(textStyle: text.labelLarge),
                    onPressed: saving ? null : onConfirm,
                    child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(saving
                            ? '正在保存…'
                            : hasConflict
                                ? '保留冲突并保存'
                                : replaceSameCourse && matches.isNotEmpty
                                    ? '合并并确认修改'
                                    : '确认修改')))),
            if (hasConflict)
              SizedBox(
                  width: double.infinity,
                  child: TextButton(
                      onPressed: saving ? null : onBackToEdit,
                      child: const Text('返回修改'))),
          ],
        )),
      ),
    );
  }
}
