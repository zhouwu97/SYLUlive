import 'package:flutter/material.dart';
import '../../utils/edu_semester_utils.dart';

enum _DrawerPage { menu, semesterList }

/// Full-height left-side drawer for grade management.
/// Matches the home screen drawer style.
class GradeManageDrawer extends StatefulWidget {
  final String selectedYear;
  final int selectedSemester;
  final int enrollmentYear;
  final Future<bool> Function(String year, int semester) onSemesterChanged;
  final Future<bool> Function() onRefresh;

  const GradeManageDrawer({
    super.key,
    required this.selectedYear,
    required this.selectedSemester,
    required this.enrollmentYear,
    required this.onSemesterChanged,
    required this.onRefresh,
  });

  @override
  State<GradeManageDrawer> createState() => _GradeManageDrawerState();
}

class _GradeManageDrawerState extends State<GradeManageDrawer> {
  _DrawerPage _page = _DrawerPage.menu;
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
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _handleSemesterTap(String year, int semester) async {
    if (_loadingSemesterKey != null) return;

    final key = '${year}_$semester';
    setState(() => _loadingSemesterKey = key);

    final success = await widget.onSemesterChanged(year, semester);

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pop();
    } else {
      setState(() => _loadingSemesterKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;

    return Drawer(
      width: (screenWidth * 0.84).clamp(300.0, 380.0),
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          right: Radius.circular(26),
        ),
      ),
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _page == _DrawerPage.menu
              ? _buildMenu(context)
              : _buildSemesterList(context),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext context) {
    return SingleChildScrollView(
      key: const ValueKey('menu'),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text(
            '成绩管理',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            '切换学期与成绩操作',
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),

          _sectionLabel('当前学期'),
          const SizedBox(height: 8),
          _drawerRow(
            icon: Icons.calendar_today_rounded,
            iconColor: Colors.blue,
            title: EduSemester.fullLabel(
              widget.selectedYear,
              widget.selectedSemester,
            ),
            trailing: const Icon(Icons.chevron_right_rounded, size: 20),
            onTap: () => setState(() => _page = _DrawerPage.semesterList),
          ),
          const SizedBox(height: 20),

          _sectionLabel('成绩操作'),
          const SizedBox(height: 8),
          _drawerRow(
            icon: Icons.refresh_rounded,
            iconColor: Colors.teal,
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

    return Column(
      key: const ValueKey('semesterList'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 20, 8),
          child: InkWell(
            onTap: () => setState(() => _page = _DrawerPage.menu),
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
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
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

  Widget _drawerRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? Colors.grey[850] : Colors.grey[100],
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: onTap == null ? Colors.grey : null,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[500],
                        ),
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
