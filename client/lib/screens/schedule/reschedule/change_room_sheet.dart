import 'package:flutter/material.dart';
import '../../../providers/course_schedule_provider.dart';
import '../../../theme/app_theme_tokens.dart';

/// 修改教室 Sheet
class ChangeRoomSheet extends StatefulWidget {
  final CourseBlock course;
  final int currentAcademicWeek;
  final void Function(Set<int> affectedWeeks, String newRoom) onConfirm;

  const ChangeRoomSheet({
    super.key,
    required this.course,
    required this.currentAcademicWeek,
    required this.onConfirm,
  });

  static Future<void> show(
    BuildContext context, {
    required CourseBlock course,
    required int currentAcademicWeek,
    required void Function(Set<int> affectedWeeks, String newRoom) onConfirm,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ChangeRoomSheet(
        course: course,
        currentAcademicWeek: currentAcademicWeek,
        onConfirm: onConfirm,
      ),
    );
  }

  @override
  State<ChangeRoomSheet> createState() => _ChangeRoomSheetState();
}

class _ChangeRoomSheetState extends State<ChangeRoomSheet> {
  bool _onlyCurrentWeek = false;
  late int _startWeek;
  late int _endWeek;
  late Set<int> _courseWeeks;
  late TextEditingController _roomController;

  @override
  void initState() {
    super.initState();
    _courseWeeks = widget.course.weeks.toSet();
    final firstWeek = widget.course.weeks.isNotEmpty ? widget.course.weeks.first : 1;
    final lastWeek = widget.course.weeks.isNotEmpty ? widget.course.weeks.last : 18;
    _startWeek = firstWeek;
    _endWeek = lastWeek;
    _roomController = TextEditingController();
  }

  @override
  void dispose() {
    _roomController.dispose();
    super.dispose();
  }

  Set<int> get _userSelectedWeeks {
    if (_onlyCurrentWeek) return {widget.currentAcademicWeek};
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
                      '修改上课教室',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: tokens.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: tokens.textSecondary, size: 20),
                    onPressed: () => Navigator.pop(context),
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
                '当前教室：${widget.course.location ?? "未指定"}  ·  原时间：周${widget.course.weekday} 第${widget.course.startSection}-${widget.course.endSection}节',
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
              RadioListTile<bool>(
                value: true,
                groupValue: _onlyCurrentWeek,
                activeColor: tokens.primary,
                contentPadding: EdgeInsets.zero,
                title: Text('仅本周 (第${widget.currentAcademicWeek}周)',
                    style: TextStyle(color: tokens.textPrimary, fontSize: 14)),
                onChanged: (val) => setState(() => _onlyCurrentWeek = val ?? false),
              ),
              RadioListTile<bool>(
                value: false,
                groupValue: _onlyCurrentWeek,
                activeColor: tokens.primary,
                contentPadding: EdgeInsets.zero,
                title: Text('指定周次范围',
                    style: TextStyle(color: tokens.textPrimary, fontSize: 14)),
                onChanged: (val) => setState(() => _onlyCurrentWeek = val ?? false),
              ),
              if (!_onlyCurrentWeek) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _buildDropdown(
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
                      child: _buildDropdown(
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
              Text(
                '新教室名称',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: tokens.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _roomController,
                autofocus: true,
                style: TextStyle(color: tokens.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: '如：A-108 或 综合楼 302',
                  hintStyle: TextStyle(color: tokens.textDisabled),
                  filled: true,
                  fillColor: tokens.inputBackground,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: tokens.outline),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: tokens.tagBackground,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '实际影响：第 ${actual.join('、')} 周 (共 ${actual.length} 周)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: actual.isEmpty ? tokens.error : tokens.primary,
                  ),
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
                      : () {
                          final room = _roomController.text.trim();
                          if (room.isEmpty) return;
                          Navigator.pop(context);
                          widget.onConfirm(_actualAffectedWeeks, room);
                        },
                  child: const Text('确认修改教室',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required int value,
    required AppThemeTokens tokens,
    required ValueChanged<int?> onChanged,
    int minWeek = 1,
  }) {
    final items = List.generate(25, (i) => i + 1).where((w) => w >= minWeek).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: tokens.textSecondary)),
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
              items: items.map((w) => DropdownMenuItem<int>(value: w, child: Text('第 $w 周'))).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
