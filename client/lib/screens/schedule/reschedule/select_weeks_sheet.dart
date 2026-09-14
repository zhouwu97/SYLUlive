import 'package:flutter/material.dart';
import '../../../providers/course_schedule_provider.dart';
import '../../../theme/app_theme_tokens.dart';
import '../../../utils/week_formatter.dart';

/// 调课第一步：选择调整周次
class SelectWeeksSheet extends StatefulWidget {
  final CourseBlock course;
  final int currentAcademicWeek;
  final int? totalTeachingWeeks;
  final Set<int>? sourceWeeks;
  final Set<int>? initialAffectedWeeks;
  final VoidCallback? onBack;
  final VoidCallback? onClose;
  final ValueChanged<Set<int>> onNext;

  const SelectWeeksSheet({
    super.key,
    required this.course,
    required this.currentAcademicWeek,
    this.totalTeachingWeeks,
    this.sourceWeeks,
    this.initialAffectedWeeks,
    this.onBack,
    this.onClose,
    required this.onNext,
  });

  static Future<Set<int>?> show(
    BuildContext context, {
    required CourseBlock course,
    required int currentAcademicWeek,
    int? totalTeachingWeeks,
    Set<int>? sourceWeeks,
    Set<int>? initialAffectedWeeks,
  }) {
    return showModalBottomSheet<Set<int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SelectWeeksSheet(
        course: course,
        currentAcademicWeek: currentAcademicWeek,
        totalTeachingWeeks: totalTeachingWeeks,
        sourceWeeks: sourceWeeks,
        initialAffectedWeeks: initialAffectedWeeks,
        onNext: (weeks) => Navigator.pop(ctx, weeks),
      ),
    );
  }

  @override
  State<SelectWeeksSheet> createState() => _SelectWeeksSheetState();
}

class _SelectWeeksSheetState extends State<SelectWeeksSheet> {
  bool _onlyCurrentWeek = false;
  late int _startWeek;
  late int _endWeek;
  late Set<int> _courseWeeks;

  @override
  void initState() {
    super.initState();
    _courseWeeks = widget.sourceWeeks?.isNotEmpty == true
        ? widget.sourceWeeks!
        : widget.course.weeks.isNotEmpty
            ? widget.course.weeks.toSet()
            : Set<int>.from(List.generate(
                widget.totalTeachingWeeks ?? widget.currentAcademicWeek,
                (i) => i + 1,
              ));
    final sortedWeeks = _courseWeeks.toList()..sort();
    final firstWeek = sortedWeeks.first;
    final lastWeek = sortedWeeks.last;

    final initial = widget.initialAffectedWeeks
        ?.where(_courseWeeks.contains)
        .toList()
      ?..sort();
    _startWeek = initial?.isNotEmpty == true ? initial!.first : firstWeek;
    _endWeek = initial?.isNotEmpty == true ? initial!.last : lastWeek;

    // 如果当前周在课程周次范围内，默认指定范围从当前周开始
    if (initial == null || initial.isEmpty) {
      if (_courseWeeks.contains(widget.currentAcademicWeek)) {
        _startWeek = widget.currentAcademicWeek;
        if (_startWeek > _endWeek) _endWeek = _startWeek;
      }
    }
    if (initial?.length == 1 && initial!.single == widget.currentAcademicWeek) {
      _onlyCurrentWeek = true;
    }
  }

  Set<int> get _userSelectedWeeks {
    if (_onlyCurrentWeek) {
      return {widget.currentAcademicWeek};
    }
    final set = <int>{};
    for (var w = _startWeek; w <= _endWeek; w++) {
      set.add(w);
    }
    return set;
  }

  Set<int> get _actualAffectedWeeks =>
      _userSelectedWeeks.intersection(_courseWeeks);

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final actual = _actualAffectedWeeks.toList()..sort();

    return SafeArea(
      top: false,
      child: Container(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: tokens.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '调整课程安排 (1/3)',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: tokens.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  icon:
                      Icon(Icons.close, color: tokens.textSecondary, size: 20),
                  onPressed: widget.onBack ?? () => Navigator.pop(context),
                ),
              ],
            ),
            Text(
              widget.course.name,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: tokens.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '当前时间：周${widget.course.weekday} 第${widget.course.startSection}-${widget.course.endSection}节  ·  课程周次：${WeekFormatter.format(widget.course.weeks, prefixWithDi: true)}',
              style: TextStyle(fontSize: 12, color: tokens.textSecondary),
            ),
            const SizedBox(height: 16),
            Divider(color: tokens.divider),
            const SizedBox(height: 12),
            Text(
              '修改范围',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: tokens.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            // 仅本周
            RadioListTile<bool>(
              value: true,
              groupValue: _onlyCurrentWeek,
              activeColor: tokens.primary,
              contentPadding: EdgeInsets.zero,
              title: Text('仅本周 (第${widget.currentAcademicWeek}周)',
                  style: TextStyle(color: tokens.textPrimary, fontSize: 14)),
              onChanged: (val) =>
                  setState(() => _onlyCurrentWeek = val ?? false),
            ),
            // 指定范围
            RadioListTile<bool>(
              value: false,
              groupValue: _onlyCurrentWeek,
              activeColor: tokens.primary,
              contentPadding: EdgeInsets.zero,
              title: Text('指定周次范围',
                  style: TextStyle(color: tokens.textPrimary, fontSize: 14)),
              onChanged: (val) =>
                  setState(() => _onlyCurrentWeek = val ?? false),
            ),
            if (!_onlyCurrentWeek) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    tooltip: '返回课程详情',
                    icon: Icon(Icons.arrow_back, color: tokens.textSecondary),
                    onPressed: widget.onClose ?? () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: _buildWeekDropdown(
                      label: '开始周',
                      value: _startWeek,
                      tokens: tokens,
                      onChanged: (val) {
                        if (val == null) return;
                        setState(() {
                          _startWeek = val;
                          if (_endWeek < _startWeek) _endWeek = _startWeek;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _buildWeekDropdown(
                      label: '结束周',
                      value: _endWeek,
                      tokens: tokens,
                      minWeek: _startWeek,
                      onChanged: (val) {
                        if (val == null) return;
                        setState(() => _endWeek = val);
                      },
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            // 实际影响提示 (Section 14)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: tokens.tagBackground,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '实际影响周次',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    actual.isEmpty
                        ? '所选范围内该课程不上课（实际影响 0 周）'
                        : '第 ${actual.join('、')} 周（共 ${actual.length} 周）',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: actual.isEmpty ? tokens.error : tokens.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.primary,
                  foregroundColor: tokens.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: actual.isEmpty
                    ? null
                    : () => widget.onNext(_actualAffectedWeeks),
                child: const Text('下一步：选择目标时间',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeekDropdown({
    required String label,
    required int value,
    required AppThemeTokens tokens,
    required ValueChanged<int?> onChanged,
    int minWeek = 1,
  }) {
    final maxWeek = widget.totalTeachingWeeks ??
        (_courseWeeks.isEmpty
            ? value
            : _courseWeeks.reduce((a, b) => a > b ? a : b));
    final items = List.generate(maxWeek, (i) => i + 1)
        .where((w) => w >= minWeek)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 12, color: tokens.textSecondary)),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: tokens.inputBackground,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tokens.outline),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: value,
              isExpanded: true,
              dropdownColor: tokens.surface,
              style: TextStyle(color: tokens.textPrimary, fontSize: 14),
              items: items.map((w) {
                return DropdownMenuItem<int>(
                  value: w,
                  child: Text('第 $w 周'),
                );
              }).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
