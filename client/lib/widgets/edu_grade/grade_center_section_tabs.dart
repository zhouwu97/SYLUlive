import 'package:flutter/material.dart';

enum GradeCenterSection { term, overview }

class GradeCenterSectionTabs extends StatelessWidget {
  final GradeCenterSection selected;
  final ValueChanged<GradeCenterSection> onChanged;

  const GradeCenterSectionTabs({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SegmentedButton<GradeCenterSection>(
        key: const ValueKey('grade_section_tabs'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment<GradeCenterSection>(
            value: GradeCenterSection.term,
            label: Text('学期成绩'),
            icon: Icon(Icons.calendar_month_outlined, size: 17),
          ),
          ButtonSegment<GradeCenterSection>(
            value: GradeCenterSection.overview,
            label: Text('学业总览'),
            icon: Icon(Icons.insights_outlined, size: 17),
          ),
        ],
        selected: <GradeCenterSection>{selected},
        onSelectionChanged: (selection) {
          if (selection.isNotEmpty) onChanged(selection.first);
        },
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: accent.withValues(alpha: isDark ? 0.2 : 0.1),
          selectedForegroundColor: accent,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
