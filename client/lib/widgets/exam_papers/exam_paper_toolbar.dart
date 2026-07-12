import 'package:flutter/material.dart';

import '../glass_container.dart';

class ExamPaperToolbar extends StatelessWidget {
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final String academicYear;
  final String semester;
  final String examType;
  final String sort;
  final List<String> academicYears;
  final ValueChanged<String> onAcademicYearChanged;
  final ValueChanged<String> onSemesterChanged;
  final ValueChanged<String> onExamTypeChanged;
  final ValueChanged<String> onSortChanged;
  final int total;
  final int activeFilterCount;
  final VoidCallback onClearSearch;
  final VoidCallback onClearFilters;

  const ExamPaperToolbar({
    super.key,
    required this.searchController,
    required this.onSearchChanged,
    required this.academicYear,
    required this.semester,
    required this.examType,
    required this.sort,
    required this.academicYears,
    required this.onAcademicYearChanged,
    required this.onSemesterChanged,
    required this.onExamTypeChanged,
    required this.onSortChanged,
    required this.total,
    required this.activeFilterCount,
    required this.onClearSearch,
    required this.onClearFilters,
  });

  Widget _buildFilters(BuildContext context) {
    final filters = [
      _CompactDropdown(
        value: academicYear,
        items: {
          '': '全部学年',
          for (final year in academicYears) year: year,
        },
        onChanged: onAcademicYearChanged,
      ),
      _CompactDropdown(
        value: semester,
        items: const {
          '': '全部学期',
          'first': '第一学期',
          'second': '第二学期',
          'other': '其他',
        },
        onChanged: onSemesterChanged,
      ),
      _CompactDropdown(
        value: examType,
        items: const {
          '': '全部类型',
          'midterm': '期中',
          'final': '期末',
          'makeup': '补考',
          'retake': '重修',
          'other': '其他',
        },
        onChanged: onExamTypeChanged,
      ),
      _CompactDropdown(
        value: sort,
        items: const {
          'latest': '最新',
          'downloads': '下载最多',
        },
        onChanged: onSortChanged,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 600) {
          return Row(
            children: [
              Expanded(child: filters[0]),
              const SizedBox(width: 4),
              Expanded(child: filters[1]),
              const SizedBox(width: 4),
              Expanded(child: filters[2]),
              const SizedBox(width: 4),
              SizedBox(width: 96, child: filters[3]),
            ],
          );
        }

        final itemWidth = (constraints.maxWidth - 4) / 2;
        return Wrap(
          spacing: 4,
          runSpacing: 4,
          children: filters
              .map((filter) => SizedBox(width: itemWidth, child: filter))
              .toList(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: GlassContainer(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        borderRadius: 14,
        blur: 0,
        showHighlight: false,
        child: Column(
          children: [
            SizedBox(
              height: 38,
              child: TextField(
                controller: searchController,
                onChanged: onSearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: '搜索课程名或关键词',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜索',
                          onPressed: onClearSearch,
                          icon: const Icon(Icons.close, size: 18),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            _buildFilters(context),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  '共 $total 份试卷',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const Spacer(),
                if (activeFilterCount > 0) ...[
                  Text(
                    '筛选 $activeFilterCount',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: onClearFilters,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(40, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                    child: const Text('清除'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactDropdown extends StatelessWidget {
  final String value;
  final Map<String, String> items;
  final ValueChanged<String> onChanged;

  const _CompactDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          isExpanded: true,
          padding: const EdgeInsets.only(left: 8, right: 4),
          borderRadius: BorderRadius.circular(12),
          icon: const Icon(Icons.arrow_drop_down, size: 18),
          style: Theme.of(context).textTheme.bodyMedium,
          items: items.entries
              .map(
                (entry) => DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value),
                ),
              )
              .toList(),
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    );
  }
}
