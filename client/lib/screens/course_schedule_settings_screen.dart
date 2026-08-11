import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/campus/campus_theme.dart';

class CourseScheduleSettingsSnapshot {
  const CourseScheduleSettingsSnapshot({
    required this.courseCount,
    required this.semesterStartText,
    required this.reminderEnabled,
    required this.reminderAdvanceMinutes,
    required this.reminderBusy,
    required this.scheduledReminderCount,
    required this.reminderSummary,
    required this.backgroundKeepAliveSubtitle,
    required this.backgroundKeepAliveReady,
    required this.backgroundKeepAliveSupported,
    required this.backgroundKeepAliveBusy,
    required this.scheduleCardOpacity,
    required this.scheduleSlotHeight,
    required this.defaultSlotHeight,
  });

  final int courseCount;
  final String semesterStartText;
  final bool reminderEnabled;
  final int reminderAdvanceMinutes;
  final bool reminderBusy;
  final int scheduledReminderCount;
  final String reminderSummary;
  final String backgroundKeepAliveSubtitle;
  final bool backgroundKeepAliveReady;
  final bool backgroundKeepAliveSupported;
  final bool backgroundKeepAliveBusy;
  final double scheduleCardOpacity;
  final double scheduleSlotHeight;
  final double defaultSlotHeight;
}

class CourseScheduleSettingsCallbacks {
  const CourseScheduleSettingsCallbacks({
    required this.reloadSnapshot,
    required this.refreshCourses,
    required this.openArchive,
    required this.pickSemesterStart,
    required this.shareSchedule,
    required this.addCustomCourse,
    required this.toggleReminder,
    required this.changeReminderAdvanceMinutes,
    required this.requestBackgroundKeepAlive,
    required this.openHomeWidgets,
    required this.updateScheduleOpacity,
    required this.updateScheduleSlotHeight,
    required this.resetScheduleDisplay,
  });

  final Future<CourseScheduleSettingsSnapshot> Function() reloadSnapshot;
  final Future<void> Function() refreshCourses;
  final Future<void> Function() openArchive;
  final Future<void> Function() pickSemesterStart;
  final Future<void> Function() shareSchedule;
  final Future<void> Function() addCustomCourse;
  final Future<void> Function(bool enabled) toggleReminder;
  final Future<void> Function(int minutes) changeReminderAdvanceMinutes;
  final Future<void> Function() requestBackgroundKeepAlive;
  final Future<void> Function() openHomeWidgets;
  final Future<void> Function(double value) updateScheduleOpacity;
  final Future<void> Function(double value) updateScheduleSlotHeight;
  final Future<void> Function() resetScheduleDisplay;
}

class CourseScheduleSettingsScreen extends StatefulWidget {
  const CourseScheduleSettingsScreen({
    super.key,
    required this.initialSnapshot,
    required this.callbacks,
  });

  final CourseScheduleSettingsSnapshot initialSnapshot;
  final CourseScheduleSettingsCallbacks callbacks;

  @override
  State<CourseScheduleSettingsScreen> createState() =>
      _CourseScheduleSettingsScreenState();
}

class _CourseScheduleSettingsScreenState
    extends State<CourseScheduleSettingsScreen> {
  late CourseScheduleSettingsSnapshot _snapshot;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initialSnapshot;
  }

  Future<void> _refreshSnapshot() async {
    final next = await widget.callbacks.reloadSnapshot();
    if (mounted) setState(() => _snapshot = next);
  }

  Future<void> _runAndRefresh(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      await _refreshSnapshot();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickReminderMinutes() async {
    final sheetTheme = CampusTheme.withBrandAccent(Theme.of(context));
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => Theme(
        data: sheetTheme,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '提醒时间',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              for (final minutes in const [5, 10, 15, 20, 30])
                ListTile(
                  title: Text('提前 $minutes 分钟'),
                  trailing: minutes == _snapshot.reminderAdvanceMinutes
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(context).pop(minutes),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) {
      await _runAndRefresh(
        () => widget.callbacks.changeReminderAdvanceMinutes(selected),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final pageBackground = CampusTheme.pageBackground(context);

    return Theme(
      data: CampusTheme.withBrandAccent(baseTheme),
      child: Scaffold(
        backgroundColor: pageBackground,
        appBar: AppBar(
          title: const Text('课表设置'),
          backgroundColor: pageBackground,
          foregroundColor: baseTheme.colorScheme.onSurface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          actions: [
            IconButton(
              tooltip: '刷新状态',
              onPressed: _busy ? null : _refreshSnapshot,
              icon: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_outlined),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          physics: const BouncingScrollPhysics(),
          children: [
            _CourseSettingsHeaderCard(snapshot: _snapshot),
            const SizedBox(height: 18),
            _CourseSettingsSection(
              title: '课表数据',
              children: [
                _CourseSettingsTile(
                  icon: Icons.cloud_download_outlined,
                  title: '从教务刷新课表',
                  subtitle: '拉取最新数据并覆盖当前课表',
                  onTap: () => _runAndRefresh(widget.callbacks.refreshCourses),
                ),
                _CourseSettingsTile(
                  icon: Icons.collections_bookmark_outlined,
                  title: '课表存档',
                  subtitle: '保存、切换、导入本地课表存档',
                  onTap: () => _runAndRefresh(widget.callbacks.openArchive),
                ),
                _CourseSettingsTile(
                  icon: Icons.event_outlined,
                  title: '设置开学第一周',
                  subtitle: _snapshot.semesterStartText,
                  onTap: () =>
                      _runAndRefresh(widget.callbacks.pickSemesterStart),
                ),
                _CourseSettingsTile(
                  icon: Icons.ios_share_outlined,
                  title: '分享本周课表',
                  subtitle: '生成文字版课表并分享',
                  onTap: () => _runAndRefresh(widget.callbacks.shareSchedule),
                ),
              ],
            ),
            _CourseSettingsSection(
              title: '课程管理',
              children: [
                _CourseSettingsTile(
                  icon: Icons.add_circle_outline,
                  title: '添加自定义课程',
                  subtitle: '手动添加 / AI 识别课表图片或文字',
                  onTap: () => _runAndRefresh(widget.callbacks.addCustomCourse),
                ),
              ],
            ),
            _CourseSettingsSection(
              title: '课程提醒',
              children: [
                SwitchListTile(
                  secondary: Icon(
                    _snapshot.reminderEnabled
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_none_outlined,
                    color: _snapshot.reminderEnabled
                        ? CampusTheme.primary
                        : CampusTheme.subText,
                  ),
                  title: const Text('课程提醒'),
                  subtitle: Text(
                    _snapshot.reminderEnabled
                        ? _snapshot.reminderSummary
                        : '已关闭课程提醒',
                  ),
                  value: _snapshot.reminderEnabled,
                  onChanged: _snapshot.reminderBusy
                      ? null
                      : (value) => _runAndRefresh(
                            () => widget.callbacks.toggleReminder(value),
                          ),
                ),
                _CourseSettingsTile(
                  icon: Icons.timer_outlined,
                  title: '提醒时间',
                  subtitle: '提前 ${_snapshot.reminderAdvanceMinutes} 分钟',
                  enabled: !_snapshot.reminderBusy,
                  onTap: _pickReminderMinutes,
                ),
                _CourseSettingsTile(
                  icon: _snapshot.backgroundKeepAliveReady
                      ? Icons.verified_user_outlined
                      : Icons.battery_alert_outlined,
                  title: '后台保活授权',
                  subtitle: _snapshot.backgroundKeepAliveSubtitle,
                  enabled: _snapshot.backgroundKeepAliveSupported &&
                      !_snapshot.backgroundKeepAliveBusy,
                  onTap: () => _runAndRefresh(
                    widget.callbacks.requestBackgroundKeepAlive,
                  ),
                ),
              ],
            ),
            _CourseSettingsSection(
              title: '课表显示',
              children: [
                _CourseDisplaySliderTile(
                  title: '课程块透明度',
                  value: _snapshot.scheduleCardOpacity,
                  min: 0.1,
                  max: 1,
                  divisions: 18,
                  valueLabel:
                      '${(_snapshot.scheduleCardOpacity * 100).round()}%',
                  onChanged: (value) {
                    setState(() {
                      _snapshot = _copySnapshot(
                        scheduleCardOpacity: value,
                      );
                    });
                    unawaited(widget.callbacks.updateScheduleOpacity(value));
                  },
                ),
                _CourseDisplaySliderTile(
                  title: '每节课高度',
                  value: _snapshot.scheduleSlotHeight,
                  min: 55,
                  max: 120,
                  divisions: 13,
                  valueLabel: '${_snapshot.scheduleSlotHeight.round()} dp',
                  onChanged: (value) {
                    setState(() {
                      _snapshot = _copySnapshot(scheduleSlotHeight: value);
                    });
                    unawaited(
                      widget.callbacks.updateScheduleSlotHeight(value),
                    );
                  },
                ),
                _CourseSettingsTile(
                  icon: Icons.restart_alt_outlined,
                  title: '恢复课表显示默认值',
                  subtitle: '仅重置课程块透明度和每节课高度',
                  onTap: () => _runAndRefresh(
                    widget.callbacks.resetScheduleDisplay,
                  ),
                ),
              ],
            ),
            _CourseSettingsSection(
              title: '桌面小组件',
              children: [
                _CourseSettingsTile(
                  icon: Icons.widgets_outlined,
                  title: '管理桌面小组件',
                  subtitle: '课表、考试、样式与尺寸',
                  onTap: () => _runAndRefresh(widget.callbacks.openHomeWidgets),
                ),
              ],
            ),
            _CourseSettingsSection(
              title: '高级维护',
              children: [
                _CourseSettingsTile(
                  icon: Icons.refresh_outlined,
                  title: '重新读取设置状态',
                  subtitle: '检查本地设置、提醒和后台权限状态',
                  onTap: _refreshSnapshot,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  CourseScheduleSettingsSnapshot _copySnapshot({
    double? scheduleCardOpacity,
    double? scheduleSlotHeight,
  }) {
    return CourseScheduleSettingsSnapshot(
      courseCount: _snapshot.courseCount,
      semesterStartText: _snapshot.semesterStartText,
      reminderEnabled: _snapshot.reminderEnabled,
      reminderAdvanceMinutes: _snapshot.reminderAdvanceMinutes,
      reminderBusy: _snapshot.reminderBusy,
      scheduledReminderCount: _snapshot.scheduledReminderCount,
      reminderSummary: _snapshot.reminderSummary,
      backgroundKeepAliveSubtitle: _snapshot.backgroundKeepAliveSubtitle,
      backgroundKeepAliveReady: _snapshot.backgroundKeepAliveReady,
      backgroundKeepAliveSupported: _snapshot.backgroundKeepAliveSupported,
      backgroundKeepAliveBusy: _snapshot.backgroundKeepAliveBusy,
      scheduleCardOpacity: scheduleCardOpacity ?? _snapshot.scheduleCardOpacity,
      scheduleSlotHeight: scheduleSlotHeight ?? _snapshot.scheduleSlotHeight,
      defaultSlotHeight: _snapshot.defaultSlotHeight,
    );
  }
}

class _CourseSettingsHeaderCard extends StatelessWidget {
  const _CourseSettingsHeaderCard({required this.snapshot});

  final CourseScheduleSettingsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const primary = CampusTheme.primary;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: isDark ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '课表管理与显示',
            style: TextStyle(
              color: primary,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusChip(label: '当前 ${snapshot.courseCount} 门课程'),
              _StatusChip(
                label: snapshot.reminderEnabled ? '课程提醒 已开启' : '课程提醒 未开启',
              ),
              _StatusChip(
                label:
                    snapshot.backgroundKeepAliveReady ? '后台权限 已授权' : '后台权限 待检查',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isDark ? CampusTheme.darkCard : CampusTheme.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: const TextStyle(fontSize: 13)),
    );
  }
}

class _CourseSettingsSection extends StatelessWidget {
  const _CourseSettingsSection({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: isDark ? CampusTheme.darkCard : CampusTheme.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark ? Colors.white10 : CampusTheme.border,
              ),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _CourseSettingsTile extends StatelessWidget {
  const _CourseSettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: enabled ? onTap : null,
    );
  }
}

class _CourseDisplaySliderTile extends StatelessWidget {
  const _CourseDisplaySliderTile({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Text(valueLabel),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
