import 'package:flutter/material.dart';
import '../../utils/edu_semester_utils.dart';

enum _SheetPage { menu, semesterList }

/// Half-screen bottom sheet for grade management.
/// Height adapts to content (max 65% screen), semester tap shows inline spinner.
class GradeManageSheet extends StatefulWidget {
  final String selectedYear;
  final int selectedSemester;
  final int enrollmentYear;
  final Future<bool> Function(String year, int semester) onSemesterChanged;
  final Future<bool> Function() onRefresh;

  const GradeManageSheet({
    super.key,
    required this.selectedYear,
    required this.selectedSemester,
    required this.enrollmentYear,
    required this.onSemesterChanged,
    required this.onRefresh,
  });

  static void show(
    BuildContext context, {
    required String selectedYear,
    required int selectedSemester,
    required int enrollmentYear,
    required Future<bool> Function(String year, int semester) onSemesterChanged,
    required Future<bool> Function() onRefresh,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GradeManageSheet(
        selectedYear: selectedYear,
        selectedSemester: selectedSemester,
        enrollmentYear: enrollmentYear,
        onSemesterChanged: onSemesterChanged,
        onRefresh: onRefresh,
      ),
    );
  }

  @override
  State<GradeManageSheet> createState() => _GradeManageSheetState();
}

class _GradeManageSheetState extends State<GradeManageSheet> {
  _SheetPage _page = _SheetPage.menu;
  bool _isRefreshing = false;
  String? _loadingSemesterKey;

  Future<void> _handleRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);

    final success = await widget.onRefresh();

    if (!mounted) return;
    setState(() => _isRefreshing = false);

    if (success) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _handleSemesterTap(String year, int semester) async {
    if (_loadingSemesterKey != null) return;

    final key = '${year}_$semester';
    setState(() => _loadingSemesterKey = key);

    final success = await widget.onSemesterChanged(year, semester);

    if (!mounted) return;

    if (success) {
      Navigator.pop(context);
    } else {
      setState(() => _loadingSemesterKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.65,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _page == _SheetPage.menu
                ? _buildMenu(context)
                : _buildSemesterList(context),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    return Padding(
      key: const ValueKey('menu'),
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '成绩管理',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          _sectionLabel('当前学期'),
          const SizedBox(height: 8),
          _menuRow(
            icon: Icons.calendar_today_rounded,
            title: EduSemester.fullLabel(
              widget.selectedYear,
              widget.selectedSemester,
            ),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => setState(() => _page = _SheetPage.semesterList),
          ),
          const SizedBox(height: 20),
          _sectionLabel('成绩操作'),
          const SizedBox(height: 8),
          _menuRow(
            icon: Icons.refresh_rounded,
            title: _isRefreshing ? '正在刷新成绩' : '刷新当前成绩',
            subtitle: _isRefreshing ? '当前页面内容不会被清空' : '重新从教务系统获取',
            trailing: _isRefreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _isRefreshing ? null : _handleRefresh,
          ),
        ],
      ),
    );
  }

  Widget _buildSemesterList(BuildContext context) {
    final semesters = EduSemester.buildSemesterList(widget.enrollmentYear);

    return Padding(
      key: const ValueKey('semesterList'),
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _page = _SheetPage.menu),
            child: Row(
              children: [
                const Icon(Icons.arrow_back_rounded, size: 20),
                const SizedBox(width: 8),
                Text(
                  '选择学期',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: () {
                String? lastYear;
                final widgets = <Widget>[];

                for (final s in semesters) {
                  if (s.year != lastYear) {
                    lastYear = s.year;
                    final y = int.parse(s.year);
                    widgets.add(
                      Padding(
                        padding: const EdgeInsets.only(top: 16, bottom: 6),
                        child: Text(
                          '$y-${y + 1}学年',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[500],
                          ),
                        ),
                      ),
                    );
                  }

                  final isSelected = s.year == widget.selectedYear &&
                      s.semester == widget.selectedSemester;
                  final key = '${s.year}_${s.semester}';
                  final isLoading = _loadingSemesterKey == key;
                  final disabled = _loadingSemesterKey != null;

                  widgets.add(
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      enabled: !disabled,
                      title: Text(EduSemester.displayLabel(s.semester)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isLoading)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          if (s.isCurrent && !isLoading)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '当前',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ),
                          if (isSelected && !isLoading)
                            Icon(
                              Icons.check_rounded,
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                        ],
                      ),
                      onTap: () => _handleSemesterTap(s.year, s.semester),
                    ),
                  );
                }
                return widgets;
              }(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Colors.grey[500],
      ),
    );
  }

  Widget _menuRow({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Theme.of(context).brightness == Brightness.dark
          ? Colors.grey[850]
          : Colors.grey[100],
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: Colors.grey[600]),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: onTap == null ? Colors.grey : null,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ),
    );
  }
}
