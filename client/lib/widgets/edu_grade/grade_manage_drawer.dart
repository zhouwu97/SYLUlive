import 'package:flutter/material.dart';
import '../../utils/edu_semester_utils.dart';

enum _DrawerPage { menu, semesterList }

/// Right-side drawer for grade management — matches home screen menu style.
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
    return Drawer(
      width: (MediaQuery.sizeOf(context).width * 0.80).clamp(300.0, 340.0),
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(
          left: Radius.circular(24),
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

  // ─── Menu page ────────────────────────────────────────────────

  Widget _buildMenu(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListView(
      key: const ValueKey('menu'),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      children: [
        // Header with close button
        Row(
          children: [
            Expanded(
              child: Text(
                '成绩管理',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            IconButton(
              tooltip: '关闭',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '切换学期与成绩操作',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 28),

        _sectionTitle('当前学期'),
        const SizedBox(height: 8),
        _menuEntry(
          icon: Icons.calendar_month_outlined,
          iconBg: cs.primaryContainer,
          iconFg: cs.primary,
          title: EduSemester.fullLabel(
            widget.selectedYear,
            widget.selectedSemester,
          ),
          trailing: Icon(Icons.chevron_right_rounded,
              size: 20, color: cs.onSurfaceVariant),
          onTap: () => setState(() => _page = _DrawerPage.semesterList),
        ),
        const SizedBox(height: 24),

        _sectionTitle('成绩操作'),
        const SizedBox(height: 8),
        _menuEntry(
          icon: Icons.refresh_rounded,
          iconBg: cs.secondaryContainer,
          iconFg: cs.secondary,
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
    );
  }

  // ─── Semester list page ───────────────────────────────────────

  Widget _buildSemesterList(BuildContext context) {
    final semesters = EduSemester.buildSemesterList(widget.enrollmentYear);
    final cs = Theme.of(context).colorScheme;

    return Column(
      key: const ValueKey('semesterList'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 20, 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => setState(() => _page = _DrawerPage.menu),
              ),
              const Text(
                '选择学期',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ],
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
                      padding: const EdgeInsets.only(top: 20, bottom: 4),
                      child: Text(
                        '$y-${y + 1}学年',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurfaceVariant,
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
                  Material(
                    color: isSelected
                        ? cs.primaryContainer.withValues(alpha: 0.3)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: ListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      enabled: !disabled,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
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
                                color: cs.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '当前',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                          if (isSelected && !isLoading)
                            Icon(Icons.check_rounded,
                                size: 20, color: cs.primary),
                        ],
                      ),
                      onTap: () => _handleSemesterTap(s.year, s.semester),
                    ),
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

  // ─── Shared helpers ───────────────────────────────────────────

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _menuEntry({
    required IconData icon,
    required Color iconBg,
    required Color iconFg,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 20, color: iconFg),
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
                        color: cs.onSurface,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
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
