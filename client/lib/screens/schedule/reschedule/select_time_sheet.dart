import 'package:flutter/material.dart';
import '../../../providers/course_schedule_provider.dart';
import '../../../theme/app_theme_tokens.dart';

/// 调课第二步：选择目标时间
class SelectTimeSheet extends StatefulWidget {
  final CourseBlock course;
  final Set<int> affectedWeeks;
  final int? initialWeekday;
  final int? initialStartSection;
  final int? initialEndSection;
  final String? initialRoom;
  final void Function(
      int weekday, int startSection, int endSection, String? newRoom) onNext;

  const SelectTimeSheet({
    super.key,
    required this.course,
    required this.affectedWeeks,
    this.initialWeekday,
    this.initialStartSection,
    this.initialEndSection,
    this.initialRoom,
    required this.onNext,
  });

  static Future<
      ({int weekday, int startSection, int endSection, String? newRoom})?> show(
    BuildContext context, {
    required CourseBlock course,
    required Set<int> affectedWeeks,
    int? initialWeekday,
    int? initialStartSection,
    int? initialEndSection,
    String? initialRoom,
  }) {
    return showModalBottomSheet<
        ({int weekday, int startSection, int endSection, String? newRoom})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SelectTimeSheet(
        course: course,
        affectedWeeks: affectedWeeks,
        initialWeekday: initialWeekday,
        initialStartSection: initialStartSection,
        initialEndSection: initialEndSection,
        initialRoom: initialRoom,
        onNext: (weekday, start, end, room) {
          Navigator.pop(ctx, (
            weekday: weekday,
            startSection: start,
            endSection: end,
            newRoom: room,
          ));
        },
      ),
    );
  }

  @override
  State<SelectTimeSheet> createState() => _SelectTimeSheetState();
}

class _SelectTimeSheetState extends State<SelectTimeSheet> {
  int _selectedWeekday = 1;
  int _selectedStartSection = 1;
  int _selectedEndSection = 2;
  late TextEditingController _roomController;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  /// 根据当前课程的真实节次范围生成候选项；研究生课表可能超过本科 12 节。
  List<({String label, int start, int end})> _availableSections() {
    final maxSection =
        [12, widget.course.endSection].reduce((a, b) => a > b ? a : b);
    final sections = <({String label, int start, int end})>[];
    for (var start = 1; start <= maxSection; start += 2) {
      final end = start + 1 <= maxSection ? start + 1 : start;
      sections.add((
        label: '$start${end == start ? '' : '-$end'}节',
        start: start,
        end: end
      ));
    }
    // 保留当前非标准范围，避免编辑已有单节或三节课程时无法回显。
    final current = (
      label: '${widget.course.startSection}-${widget.course.endSection}节',
      start: widget.course.startSection,
      end: widget.course.endSection
    );
    if (!sections.any(
        (item) => item.start == current.start && item.end == current.end)) {
      sections.add(current);
    }
    sections.sort((a, b) => a.start.compareTo(b.start));
    return sections;
  }

  @override
  void initState() {
    super.initState();
    _selectedWeekday = widget.initialWeekday ?? widget.course.weekday;
    _selectedStartSection =
        widget.initialStartSection ?? widget.course.startSection;
    _selectedEndSection = widget.initialEndSection ?? widget.course.endSection;
    _roomController = TextEditingController(
        text: widget.initialRoom ?? widget.course.location ?? '');
  }

  @override
  void dispose() {
    _roomController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final sortedWeeks = widget.affectedWeeks.toList()..sort();
    final sections = _availableSections();

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
        child: SingleChildScrollView(
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
                      '选择新的上课时间 (2/3)',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: tokens.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close,
                        color: tokens.textSecondary, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Text(
                '调整课程：${widget.course.name}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: tokens.primary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '调整范围：第 ${sortedWeeks.join('、')} 周  ·  原时间：周${widget.course.weekday} 第${widget.course.startSection}-${widget.course.endSection}节',
                style: TextStyle(fontSize: 12, color: tokens.textSecondary),
              ),
              const SizedBox(height: 16),
              Divider(color: tokens.divider),
              const SizedBox(height: 12),
              Text(
                '目标星期',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tokens.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(7, (i) {
                  final day = i + 1;
                  final isSelected = _selectedWeekday == day;
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _selectedWeekday = day),
                    child: Container(
                      width: 42,
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? tokens.primary
                            : tokens.inputBackground,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected ? tokens.primary : tokens.outline,
                        ),
                      ),
                      child: Text(
                        _weekdays[i],
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? tokens.onPrimary
                              : tokens.textPrimary,
                        ),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 16),
              Text(
                '目标节次',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tokens.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: sections.map((sec) {
                  final isSelected = _selectedStartSection == sec.start &&
                      _selectedEndSection == sec.end;
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() {
                      _selectedStartSection = sec.start;
                      _selectedEndSection = sec.end;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? tokens.primary
                            : tokens.inputBackground,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected ? tokens.primary : tokens.outline,
                        ),
                      ),
                      child: Text(
                        sec.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: isSelected
                              ? tokens.onPrimary
                              : tokens.textPrimary,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Text(
                '教室 (选填)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tokens.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _roomController,
                style: TextStyle(color: tokens.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: '如：XX-430 或 A-108',
                  hintStyle: TextStyle(color: tokens.textDisabled),
                  filled: true,
                  fillColor: tokens.inputBackground,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: tokens.outline),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // 新时间预览 (Section 19)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: tokens.tagBackground,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.schedule, size: 20, color: tokens.primary),
                    const SizedBox(width: 8),
                    Text(
                      '新时间：周${_weekdays[_selectedWeekday - 1]} 第$_selectedStartSection-$_selectedEndSection节',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: tokens.primary,
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
                  onPressed: () {
                    final room = _roomController.text.trim();
                    widget.onNext(
                      _selectedWeekday,
                      _selectedStartSection,
                      _selectedEndSection,
                      room.isNotEmpty ? room : null,
                    );
                  },
                  child: const Text('下一步：冲突检查与确认',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
