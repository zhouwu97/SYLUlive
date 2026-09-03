import 'package:flutter/material.dart';
import '../../utils/edu_semester_utils.dart';
import '../../models/edu_academic_situation.dart';
import '../../models/edu_grade.dart';
import '../../models/grade_reminder_status.dart';
import '../../services/grade_reminder_service.dart';

enum _DrawerPage { menu, semesterList }

class GradeManageDrawer extends StatefulWidget {
  final String selectedYear;
  final int selectedSemester;
  final List<EduGrade> grades;
  final String? userId;
  final bool isEduBound;
  final int enrollmentYear;
  final Future<bool> Function(String year, int semester) onSemesterChanged;
  final Future<List<EduGrade>?> Function({bool silent})? onRefreshGrades;
  final Future<bool> Function()? onRefreshAcademic;
  final EduAcademicSituation? academicSituation;
  final bool isAcademicRefreshing;

  const GradeManageDrawer({
    super.key,
    required this.selectedYear,
    required this.selectedSemester,
    required this.grades,
    required this.userId,
    required this.isEduBound,
    required this.enrollmentYear,
    required this.onSemesterChanged,
    this.onRefreshGrades,
    this.onRefreshAcademic,
    this.academicSituation,
    this.isAcademicRefreshing = false,
  });

  @override
  State<GradeManageDrawer> createState() => _GradeManageDrawerState();
}

class _GradeManageDrawerState extends State<GradeManageDrawer> {
  _DrawerPage _page = _DrawerPage.menu;
  bool _isRefreshingGrades = false;
  bool _isRefreshingAcademic = false;
  bool _isReminderBusy = false;
  bool _isCheckingNow = false;
  GradeReminderStatus _reminderStatus = const GradeReminderStatus.unsupported();
  String? _loadingSemesterKey;

  @override
  void initState() {
    super.initState();
    _loadReminderStatus();
  }

  @override
  void didUpdateWidget(covariant GradeManageDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.selectedYear != widget.selectedYear ||
        oldWidget.selectedSemester != widget.selectedSemester) {
      _loadReminderStatus();
    }
  }

  Future<void> _loadReminderStatus() async {
    final status = await GradeReminderService.instance.getStatus(
      userId: widget.userId,
    );
    if (!mounted) return;
    setState(() => _reminderStatus = status);
  }

  Future<void> _handleRefreshGrades() async {
    if (_isRefreshingGrades || widget.onRefreshGrades == null) return;
    setState(() => _isRefreshingGrades = true);
    final data = await widget.onRefreshGrades!();
    if (!mounted) return;
    setState(() => _isRefreshingGrades = false);
    if (data != null) {
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) Navigator.of(context).pop();
    }
  }

  Future<void> _handleRefreshAcademic() async {
    if (_isRefreshingAcademic || widget.onRefreshAcademic == null) return;
    setState(() => _isRefreshingAcademic = true);
    await widget.onRefreshAcademic!();
    if (!mounted) return;
    setState(() => _isRefreshingAcademic = false);
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

  Future<void> _handleReminderToggle(bool enabled) async {
    final userId = widget.userId;
    if (_isReminderBusy) return;
    if (userId == null) {
      _showSnackBar('请先登录后再开启成绩提醒');
      return;
    }
    if (enabled && !widget.isEduBound) {
      _showSnackBar('请先绑定教务账号');
      return;
    }
    if (enabled) {
      final confirmed = await _showReminderConfirmSheet();
      if (confirmed != true || !mounted) return;
    }

    setState(() => _isReminderBusy = true);

    List<EduGrade> currentGrades = widget.grades;
    if (enabled && widget.onRefreshGrades != null) {
      final freshGrades = await widget.onRefreshGrades!(silent: true);
      if (!mounted) return;
      if (freshGrades == null) {
        setState(() => _isReminderBusy = false);
        _showSnackBar('由于无法获取最新成绩，开启提醒失败');
        return;
      }
      currentGrades = freshGrades;
    }

    final status = await GradeReminderService.instance.setEnabled(
      enabled: enabled,
      userId: userId,
      year: widget.selectedYear,
      semester: widget.selectedSemester,
      grades: currentGrades,
    );
    if (!mounted) return;
    setState(() {
      _reminderStatus = status;
      _isReminderBusy = false;
    });

    if (enabled) {
      if (!status.enabled && !status.notificationGranted) {
        _showSnackBar('未获得通知权限，成绩提醒未开启');
      } else if (status.enabled && !status.backgroundReady) {
        _showSnackBar('成绩提醒已开启，建议打开后台权限提升稳定性');
      } else if (status.enabled) {
        _showSnackBar('成绩提醒已开启，已同步当前成绩作为基准');
      }
    }
  }

  Future<void> _handleReminderPermissionAction() async {
    if (!_reminderStatus.notificationGranted) {
      await GradeReminderService.instance.openNotificationSettings();
    } else if (_reminderStatus.enabled && !_reminderStatus.backgroundReady) {
      await GradeReminderService.instance.openKeepAliveSettings();
    }
    await _loadReminderStatus();
  }

  Future<bool?> _showReminderConfirmSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
    final textColor = isDark ? Colors.white : const Color(0xFF1F2328);
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF697077);

    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF171A1D) : Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 6, 22, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '开启成绩更新提醒',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '开启后，系统会在本机约每 3~4 小时检查当前学期成绩。发现新成绩或成绩变化时，会通过本地通知提醒你。',
                  style: TextStyle(fontSize: 14, height: 1.5, color: subColor),
                ),
                const SizedBox(height: 8),
                Text(
                  '需要保持登录状态、教务已绑定，并建议允许通知和后台运行权限。',
                  style: TextStyle(fontSize: 14, height: 1.5, color: subColor),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('暂不开启'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: isDark ? Colors.black : Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('开启提醒'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Drawer(
      width: (MediaQuery.sizeOf(context).width * 0.80).clamp(300.0, 340.0),
      elevation: 0,
      backgroundColor:
          isDark ? const Color(0xFF111315) : const Color(0xFFFFFAF4),
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

  Widget _buildMenu(BuildContext context) {
    return ListView(
      key: const ValueKey('menu'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 22),
      children: [
        _buildDrawerHeader(),
        const SizedBox(height: 18),
        _buildCompactAcademicCard(context),
        const SizedBox(height: 18),
        _sectionTitle('当前学期'),
        const SizedBox(height: 8),
        _semesterEntry(),
        const SizedBox(height: 18),
        _sectionTitle('操作'),
        const SizedBox(height: 8),
        _buildActionRow(),
        const SizedBox(height: 12),
        _buildReminderCard(),
      ],
    );
  }

  Widget _buildDrawerHeader() {
    return Row(
      children: [
        const Expanded(
          child: Text(
            '成绩管理',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }

  Widget _buildCompactAcademicCard(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF7A8087);
    final borderColor =
        isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE2EFEA);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: isDark
            ? null
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white, Color(0xFFF1FBF7)],
              ),
        color: isDark ? const Color(0xFF1E2226) : null,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '官方 GPA',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (widget.isAcademicRefreshing || _isRefreshingAcademic)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (widget.academicSituation != null) ...[
            Row(
              children: [
                Expanded(
                  child: _gpaMiniMetric(
                    '全部课程',
                    widget.academicSituation!.allGpa?.toStringAsFixed(2) ??
                        '--',
                    accent,
                    subColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _gpaMiniMetric(
                    '学位课',
                    widget.academicSituation!.degreeGpa?.toStringAsFixed(2) ??
                        '--',
                    accent,
                    subColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _statPill('计划', widget.academicSituation!.totalCourses, accent),
                _statPill(
                    '通过', widget.academicSituation!.passedCourses, accent),
                _statPill(
                    '未过', widget.academicSituation!.failedCourses, accent),
                _statPill(
                    '在读', widget.academicSituation!.inProgressCourses, accent),
                _statPill(
                    '未修', widget.academicSituation!.notStartedCourses, accent),
              ],
            ),
          ] else ...[
            Row(
              children: [
                Expanded(child: _gpaMiniMetric('全部课程', '--', accent, subColor)),
                const SizedBox(width: 12),
                Expanded(child: _gpaMiniMetric('学位课', '--', accent, subColor)),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              '暂未获取到学业总览',
              style: TextStyle(fontSize: 12, color: subColor),
            ),
          ],
        ],
      ),
    );
  }

  Widget _gpaMiniMetric(
      String label, String value, Color accent, Color subColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: accent,
              height: 1.1),
        ),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(fontSize: 12, color: subColor)),
      ],
    );
  }

  Widget _statPill(String label, int value, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label $value',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: accent,
        ),
      ),
    );
  }

  Widget _semesterEntry() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
    final titleColor = isDark ? Colors.white : const Color(0xFF1F2328);

    return Material(
      color: isDark ? const Color(0xFF1E2226) : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => setState(() => _page = _DrawerPage.semesterList),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFE6E8EB),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isDark
                      ? accent.withValues(alpha: 0.12)
                      : const Color(0xFFEAF6F3),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.calendar_month_outlined,
                    size: 18, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  EduSemester.fullLabel(
                      widget.selectedYear, widget.selectedSemester),
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: titleColor),
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 20,
                  color: isDark ? Colors.grey.shade500 : Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionRow() {
    if (widget.onRefreshAcademic == null) {
      return _actionButton(
        icon: Icons.refresh_rounded,
        label: '刷新当前成绩',
        onTap: _handleRefreshGrades,
        loading: _isRefreshingGrades,
        fullWidth: true,
      );
    }

    return Row(
      children: [
        Expanded(
          child: _actionButton(
            icon: Icons.refresh_rounded,
            label: '刷新成绩',
            onTap: _handleRefreshGrades,
            loading: _isRefreshingGrades,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _actionButton(
            icon: Icons.sync_rounded,
            label: '刷新总览',
            onTap: _handleRefreshAcademic,
            loading: _isRefreshingAcademic || widget.isAcademicRefreshing,
          ),
        ),
      ],
    );
  }

  Widget _buildReminderCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
    final textColor = isDark ? Colors.white : const Color(0xFF1F2328);
    final subColor = isDark ? Colors.grey.shade400 : const Color(0xFF7A8087);
    final enabled = _reminderStatus.supported && _reminderStatus.enabled;
    final needsNotification = _reminderStatus.supported &&
        enabled &&
        !_reminderStatus.notificationGranted;
    final needsBackground = _reminderStatus.supported &&
        enabled &&
        _reminderStatus.notificationGranted &&
        !_reminderStatus.backgroundReady;
    final warningColor =
        isDark ? const Color(0xFFF4B860) : const Color(0xFFC47C14);
    final statusColor = needsNotification || needsBackground
        ? warningColor
        : enabled
            ? accent
            : subColor;

    return Material(
      color: isDark ? const Color(0xFF1E2226) : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: !_reminderStatus.supported
            ? null
            : () {
                if (!_reminderStatus.notificationGranted) {
                  GradeReminderService.instance.openNotificationSettings();
                } else if (_reminderStatus.enabled &&
                    !_reminderStatus.backgroundReady) {
                  GradeReminderService.instance.openKeepAliveSettings();
                } else {
                  _loadReminderStatus();
                }
              },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFE6E8EB),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.notifications_active_outlined,
                        size: 18, color: accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '成绩更新提醒',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '约每 3~4 小时检查一次，有新成绩会通知你',
                          style: TextStyle(fontSize: 12, color: subColor),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _reminderStatus.statusText,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: statusColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _isReminderBusy
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8, right: 10),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: accent,
                            ),
                          ),
                        )
                      : Transform.scale(
                          scale: 0.82,
                          child: Switch(
                            value: enabled,
                            activeThumbColor: accent,
                            onChanged: _reminderStatus.supported
                                ? _handleReminderToggle
                                : null,
                          ),
                        ),
                ],
              ),
              if (enabled) ...[
                const SizedBox(height: 12),
                _buildReminderStatusDetail(
                  isDark: isDark,
                  accent: accent,
                  subColor: subColor,
                  textColor: textColor,
                ),
              ],
              if (needsNotification || needsBackground) ...[
                const SizedBox(height: 12),
                _buildReminderPermissionHint(
                  isDark: isDark,
                  warningColor: warningColor,
                  title: needsNotification ? '开启通知权限' : '开启后台运行权限',
                  message: needsNotification
                      ? '没有通知权限时，发现新成绩也无法提醒你。'
                      : '允许后台运行和电池优化白名单后，定时检查会更稳定。',
                  buttonText: needsNotification ? '去开启' : '去设置',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReminderPermissionHint({
    required bool isDark,
    required Color warningColor,
    required String title,
    required String message,
    required String buttonText,
  }) {
    final hintBg = isDark
        ? warningColor.withValues(alpha: 0.12)
        : warningColor.withValues(alpha: 0.08);
    final hintBorder = warningColor.withValues(alpha: isDark ? 0.24 : 0.18);
    final bodyColor = isDark ? Colors.grey.shade300 : const Color(0xFF6B5B3E);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: hintBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: hintBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: warningColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: warningColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style:
                      TextStyle(fontSize: 11, height: 1.35, color: bodyColor),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _handleReminderPermissionAction,
            style: TextButton.styleFrom(
              minimumSize: const Size(58, 34),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              foregroundColor: warningColor,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }

  Future<void> _handleCheckNow() async {
    if (_isCheckingNow) return;
    setState(() => _isCheckingNow = true);
    await GradeReminderService.instance.runCheckNow();
    // 给 OneTimeWorkRequest 一点时间起跑并写入 lastCheckAt，然后刷新状态。
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    await _loadReminderStatus();
    if (mounted) setState(() => _isCheckingNow = false);
  }

  Widget _buildReminderStatusDetail({
    required bool isDark,
    required Color accent,
    required Color subColor,
    required Color textColor,
  }) {
    final status = _reminderStatus;
    final now = DateTime.now();
    final stale = status.lastCheckAt == null ||
        now.difference(status.lastCheckAt!.toLocal()) >
            const Duration(hours: 6);
    final warningColor =
        isDark ? const Color(0xFFF4B860) : const Color(0xFFC47C14);

    String fmt(DateTime? t) {
      if (t == null) return '未记录';
      final l = t.toLocal();
      return '${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} '
          '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.04)
                : const Color(0xFFF6F7F8),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _statusRow('上次检查', fmt(status.lastCheckAt), subColor, textColor),
              const SizedBox(height: 4),
              _statusRow(
                  '上次成功', fmt(status.lastSuccessAt), subColor, textColor),
              const SizedBox(height: 4),
              _statusRow('连续失败', '${status.consecutiveFailures} 次', subColor,
                  textColor),
              if (status.needAction != null) ...[
                const SizedBox(height: 4),
                _statusRow('需要处理', _needActionText(status.needAction!),
                    subColor, warningColor),
              ],
            ],
          ),
        ),
        if (stale) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            decoration: BoxDecoration(
              color: warningColor.withValues(alpha: isDark ? 0.12 : 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: warningColor.withValues(alpha: isDark ? 0.24 : 0.18),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: warningColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status.lastCheckAt == null
                        ? '后台尚未执行过检查，建议开启后台保活/电池无限制。'
                        : '距上次后台检查已超过 6 小时，系统可能限制了后台运行。',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: isDark
                          ? Colors.grey.shade300
                          : const Color(0xFF6B5B3E),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () =>
                      GradeReminderService.instance.openKeepAliveSettings(),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(58, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    foregroundColor: warningColor,
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  child: const Text('去设置'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
        _actionButton(
          icon: Icons.bolt_outlined,
          label: _isCheckingNow ? '检查中…' : '立即检查一次',
          onTap: _isCheckingNow ? null : _handleCheckNow,
          loading: _isCheckingNow,
          fullWidth: true,
        ),
      ],
    );
  }

  Widget _statusRow(
      String label, String value, Color subColor, Color valueColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: subColor)),
        Text(
          value,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: valueColor),
        ),
      ],
    );
  }

  String _needActionText(String action) {
    switch (action) {
      case 'login':
        return '重新登录';
      case 'bind':
        return '重新绑定教务';
      case 'edu':
        return '教务服务暂不可用';
      default:
        return action;
    }
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool loading = false,
    bool fullWidth = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
    final textColor = isDark ? Colors.white : const Color(0xFF1F2328);

    return Material(
      color: isDark ? const Color(0xFF1E2226) : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: loading ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color(0xFFE6E8EB),
            ),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (loading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: accent),
                )
              else
                Icon(icon, size: 18, color: accent),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

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

  Widget _buildSemesterList(BuildContext context) {
    final semesters = EduSemester.buildSemesterList(widget.enrollmentYear);
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final accent = isDark ? const Color(0xFF7ED6C5) : const Color(0xFF147C72);
    final selectedBg =
        isDark ? const Color(0xFF1D3A36) : const Color(0xFFEAF6F3);

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
                    color: isSelected ? selectedBg : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: ListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 12),
                      enabled: !disabled,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      title: Text(
                        EduSemester.displayLabel(s.semester),
                        style: TextStyle(
                          color: isSelected ? accent : cs.onSurface,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isLoading)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: accent,
                                ),
                              ),
                            ),
                          if (s.isCurrent && !isLoading)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '当前',
                                style: TextStyle(fontSize: 12, color: accent),
                              ),
                            ),
                          if (isSelected && !isLoading)
                            Icon(Icons.check_rounded, size: 20, color: accent),
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
}
