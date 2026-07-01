import 'dart:async';

import 'package:flutter/material.dart';

class CourseWidgetPreviewItem {
  const CourseWidgetPreviewItem({
    required this.name,
    required this.timeText,
    this.location,
  });

  final String name;
  final String timeText;
  final String? location;
}

class CourseScheduleSettingsSnapshot {
  const CourseScheduleSettingsSnapshot({
    required this.courseCount,
    required this.reminderEnabled,
    required this.reminderAdvanceMinutes,
    required this.reminderBusy,
    required this.scheduledReminderCount,
    required this.reminderSummary,
    required this.backgroundKeepAliveSubtitle,
    required this.backgroundKeepAliveReady,
    required this.backgroundKeepAliveSupported,
    required this.backgroundKeepAliveBusy,
    required this.cardOpacity,
    required this.slotHeight,
    required this.defaultSlotHeight,
    required this.widgetTextColor,
    required this.appearanceSummary,
    required this.widgetSyncText,
    required this.previewCourses,
  });

  final int courseCount;
  final bool reminderEnabled;
  final int reminderAdvanceMinutes;
  final bool reminderBusy;
  final int scheduledReminderCount;
  final String reminderSummary;
  final String backgroundKeepAliveSubtitle;
  final bool backgroundKeepAliveReady;
  final bool backgroundKeepAliveSupported;
  final bool backgroundKeepAliveBusy;
  final double cardOpacity;
  final double slotHeight;
  final double defaultSlotHeight;
  final String widgetTextColor;
  final String appearanceSummary;
  final String widgetSyncText;
  final List<CourseWidgetPreviewItem> previewCourses;
}

class CourseScheduleSettingsCallbacks {
  const CourseScheduleSettingsCallbacks({
    required this.reloadSnapshot,
    required this.refreshCourses,
    required this.openArchive,
    required this.pickSemesterStart,
    required this.shareSchedule,
    required this.addCustomCourse,
    required this.renameWidget,
    required this.toggleReminder,
    required this.changeReminderAdvanceMinutes,
    required this.requestBackgroundKeepAlive,
    required this.syncWidget,
    required this.updateOpacity,
    required this.updateSlotHeight,
    required this.updateWidgetTextColor,
    required this.resetAppearance,
  });

  final Future<CourseScheduleSettingsSnapshot> Function() reloadSnapshot;
  final Future<void> Function() refreshCourses;
  final Future<void> Function() openArchive;
  final Future<void> Function() pickSemesterStart;
  final Future<void> Function() shareSchedule;
  final Future<void> Function() addCustomCourse;
  final Future<void> Function() renameWidget;
  final Future<void> Function(bool enabled) toggleReminder;
  final Future<void> Function(int minutes) changeReminderAdvanceMinutes;
  final Future<void> Function() requestBackgroundKeepAlive;
  final Future<void> Function() syncWidget;
  final Future<void> Function(double value) updateOpacity;
  final Future<void> Function(double value) updateSlotHeight;
  final Future<void> Function(String hexColor) updateWidgetTextColor;
  final Future<void> Function() resetAppearance;
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
  bool _refreshing = false;
  String? _localWidgetSyncText;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initialSnapshot;
  }

  Future<void> _refreshSnapshot() async {
    final next = await widget.callbacks.reloadSnapshot();
    if (!mounted) return;
    setState(() => _snapshot = next);
  }

  Future<void> _runAndRefresh(Future<void> Function() action) async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await action();
    } finally {
      await _refreshSnapshot();
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _syncWidget() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.callbacks.syncWidget();
      if (mounted) setState(() => _localWidgetSyncText = '刚刚同步');
    } finally {
      await _refreshSnapshot();
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _openAppearance() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CourseWidgetAppearanceScreen(
          snapshot: _snapshot,
          callbacks: widget.callbacks,
        ),
      ),
    );
    await _refreshSnapshot();
  }

  Future<void> _pickReminderMinutes() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _CourseSheetTitle(title: '提醒时间'),
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
    );
    if (selected == null) return;
    await _runAndRefresh(
      () => widget.callbacks.changeReminderAdvanceMinutes(selected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('课表设置'),
        actions: [
          IconButton(
            tooltip: '刷新状态',
            onPressed: _refreshing ? null : _refreshSnapshot,
            icon: _refreshing
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
                title: '设置开学第一天',
                subtitle: '用于计算当前是第几周',
                onTap: () => _runAndRefresh(widget.callbacks.pickSemesterStart),
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
            title: '提醒权限',
            children: [
              _CourseSettingsSwitchTile(
                icon: Icons.notifications_active_outlined,
                title: '课程提醒',
                subtitle: _snapshot.reminderSummary,
                value: _snapshot.reminderEnabled,
                busy: _snapshot.reminderBusy,
                onChanged: (value) => _runAndRefresh(
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
                trailing: _snapshot.backgroundKeepAliveBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                enabled: _snapshot.backgroundKeepAliveSupported &&
                    !_snapshot.backgroundKeepAliveBusy,
                onTap: () => _runAndRefresh(
                  widget.callbacks.requestBackgroundKeepAlive,
                ),
              ),
            ],
          ),
          _CourseSettingsSection(
            title: '桌面小组件',
            children: [
              _CourseSettingsTile(
                icon: Icons.edit_outlined,
                title: '更名小组件',
                subtitle: '自定义桌面小组件标题',
                onTap: () => _runAndRefresh(widget.callbacks.renameWidget),
              ),
              _CourseSettingsTile(
                icon: Icons.sync_outlined,
                title: '立即同步小组件',
                subtitle: _localWidgetSyncText ?? _snapshot.widgetSyncText,
                onTap: _syncWidget,
              ),
            ],
          ),
          _CourseSettingsSection(
            title: '外观显示',
            children: [
              _CourseSettingsTile(
                icon: Icons.palette_outlined,
                title: '桌面小组件外观',
                subtitle: _snapshot.appearanceSummary,
                onTap: _openAppearance,
              ),
            ],
          ),
          _CourseSettingsSection(
            title: '高级维护',
            children: [
              _CourseSettingsTile(
                icon: Icons.restart_alt_outlined,
                iconColor: colorScheme.error,
                title: '重置显示设置',
                subtitle: '恢复透明度、方块高度和字体颜色',
                onTap: () => _runAndRefresh(widget.callbacks.resetAppearance),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class CourseWidgetAppearanceScreen extends StatefulWidget {
  const CourseWidgetAppearanceScreen({
    super.key,
    required this.snapshot,
    required this.callbacks,
  });

  final CourseScheduleSettingsSnapshot snapshot;
  final CourseScheduleSettingsCallbacks callbacks;

  @override
  State<CourseWidgetAppearanceScreen> createState() =>
      _CourseWidgetAppearanceScreenState();
}

class _CourseWidgetAppearanceScreenState
    extends State<CourseWidgetAppearanceScreen> {
  late double _opacity;
  late double _slotHeight;
  late String _textColor;

  @override
  void initState() {
    super.initState();
    _opacity = widget.snapshot.cardOpacity;
    _slotHeight = widget.snapshot.slotHeight;
    _textColor = widget.snapshot.widgetTextColor;
  }

  Future<void> _resetAppearance() async {
    await widget.callbacks.resetAppearance();
    final next = await widget.callbacks.reloadSnapshot();
    if (!mounted) return;
    setState(() {
      _opacity = next.cardOpacity;
      _slotHeight = next.slotHeight;
      _textColor = next.widgetTextColor;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('桌面小组件外观')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        physics: const BouncingScrollPhysics(),
        children: [
          _CourseAppearancePreviewCard(
            opacity: _opacity,
            slotHeight: _slotHeight,
            textColor: _parseHexColor(_textColor),
            courses: widget.snapshot.previewCourses,
          ),
          const SizedBox(height: 18),
          _CourseAppearanceSliderTile(
            title: '透明度',
            startLabel: '透明',
            endLabel: '实色',
            valueLabel: '${(_opacity * 100).round()}%',
            value: _opacity,
            min: 0.1,
            max: 1.0,
            divisions: 18,
            onChanged: (value) {
              setState(() => _opacity = value);
              unawaited(widget.callbacks.updateOpacity(value));
            },
          ),
          const SizedBox(height: 12),
          _CourseAppearanceSliderTile(
            title: '方块高度',
            startLabel: '紧凑',
            endLabel: '宽松',
            valueLabel: _slotHeight.round().toString(),
            value: _slotHeight,
            min: 55,
            max: 120,
            divisions: 13,
            onChanged: (value) {
              setState(() => _slotHeight = value);
              unawaited(widget.callbacks.updateSlotHeight(value));
            },
          ),
          const SizedBox(height: 12),
          _CourseColorChoiceTile(
            selectedColor: _textColor,
            onChanged: (hexColor) {
              setState(() => _textColor = hexColor);
              unawaited(widget.callbacks.updateWidgetTextColor(hexColor));
            },
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _resetAppearance,
            icon: const Icon(Icons.restart_alt_outlined),
            label: const Text('恢复默认外观'),
          ),
        ],
      ),
    );
  }
}

class _CourseSettingsHeaderCard extends StatelessWidget {
  const _CourseSettingsHeaderCard({required this.snapshot});

  final CourseScheduleSettingsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: isDark ? 0.18 : 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: isDark ? 0.24 : 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '提醒、权限与课表管理',
            style: TextStyle(
              color: colorScheme.primary,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            runSpacing: 10,
            spacing: 10,
            children: [
              _CourseStatusChip(
                icon: Icons.menu_book_outlined,
                label: '当前 ${snapshot.courseCount} 门课程',
              ),
              _CourseStatusChip(
                icon: Icons.notifications_none,
                label: snapshot.reminderEnabled ? '课程提醒 已开启' : '课程提醒 未开启',
              ),
              _CourseStatusChip(
                icon: snapshot.backgroundKeepAliveReady
                    ? Icons.verified_user_outlined
                    : Icons.security_outlined,
                label:
                    snapshot.backgroundKeepAliveReady ? '后台权限 已授权' : '后台权限 待检查',
              ),
              _CourseStatusChip(
                icon: Icons.widgets_outlined,
                label: snapshot.widgetSyncText,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CourseStatusChip extends StatelessWidget {
  const _CourseStatusChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
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
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : const Color(0xFF111827),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFFE5E7EB),
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
    this.iconColor,
    this.trailing,
    this.enabled = true,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      enabled: enabled,
      leading:
          Icon(icon, color: enabled ? iconColor ?? colorScheme.primary : null),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: enabled ? onTap : null,
    );
  }
}

class _CourseSettingsSwitchTile extends StatelessWidget {
  const _CourseSettingsSwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: busy ? null : onChanged,
    );
  }
}

class _CourseAppearancePreviewCard extends StatelessWidget {
  const _CourseAppearancePreviewCard({
    required this.opacity,
    required this.slotHeight,
    required this.textColor,
    required this.courses,
  });

  final double opacity;
  final double slotHeight;
  final Color textColor;
  final List<CourseWidgetPreviewItem> courses;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '今日课程',
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '桌面小组件预览',
            style: TextStyle(color: textColor.withValues(alpha: 0.68)),
          ),
          const SizedBox(height: 12),
          if (courses.isEmpty)
            Container(
              height: slotHeight.clamp(55, 120).toDouble(),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: opacity),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text('今天暂无课程', style: TextStyle(color: textColor)),
            )
          else
            ...courses.take(3).map(
                  (course) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      height: slotHeight.clamp(55, 120).toDouble(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primary.withValues(alpha: opacity),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  course.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: textColor,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                if ((course.location ?? '').isNotEmpty)
                                  Text(
                                    course.location!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: textColor.withValues(alpha: 0.72),
                                      fontSize: 12,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            course.timeText,
                            style: TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}

class _CourseAppearanceSliderTile extends StatelessWidget {
  const _CourseAppearanceSliderTile({
    required this.title,
    required this.startLabel,
    required this.endLabel,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String title;
  final String startLabel;
  final String endLabel;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(valueLabel),
            ],
          ),
          Row(
            children: [
              Text(startLabel, style: const TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: value,
                  min: min,
                  max: max,
                  divisions: divisions,
                  label: valueLabel,
                  onChanged: onChanged,
                ),
              ),
              Text(endLabel, style: const TextStyle(fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

class _CourseColorChoiceTile extends StatelessWidget {
  const _CourseColorChoiceTile({
    required this.selectedColor,
    required this.onChanged,
  });

  final String selectedColor;
  final ValueChanged<String> onChanged;

  static const _colors = [
    ('#333333', '深灰'),
    ('#888888', '浅灰'),
    ('#FFFFFF', '白色'),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('字体颜色', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final color in _colors)
                ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: _parseHexColor(color.$1),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(color.$2),
                    ],
                  ),
                  selected: selectedColor.toUpperCase() == color.$1,
                  onSelected: (_) => onChanged(color.$1),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CourseSheetTitle extends StatelessWidget {
  const _CourseSheetTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

Color _parseHexColor(String hexColor) {
  final normalized = hexColor.replaceFirst('#', '');
  final value = int.tryParse(normalized, radix: 16) ?? 0x333333;
  return Color(0xFF000000 | value);
}
