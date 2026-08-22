import 'package:flutter/material.dart';

import '../../models/user_calendar.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';

class AiCalendarActionDraftCard extends StatefulWidget {
  const AiCalendarActionDraftCard({
    super.key,
    required this.draft,
    this.onConfirm,
    this.onCancel,
  });

  final UserCalendarActionDraft draft;
  final Future<void> Function()? onConfirm;
  final Future<void> Function()? onCancel;

  @override
  State<AiCalendarActionDraftCard> createState() =>
      _AiCalendarActionDraftCardState();
}

class _AiCalendarActionDraftCardState extends State<AiCalendarActionDraftCard> {
  bool _busy = false;

  Future<void> _run(Future<void> Function()? action) async {
    if (_busy || action == null || !widget.draft.isPending) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final colors = Theme.of(context).colorScheme;
    final pending = draft.isPending && !draft.isExpired;
    final danger = draft.actionType == 'calendar_event_delete';
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.surfaceSecondaryDark
            : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: danger
              ? AppColors.danger.withValues(alpha: 0.28)
              : AppColors.borderNormalLight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconFor(draft.actionType),
                  size: 20,
                  color: danger ? AppColors.danger : AppColors.brandPrimary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _titleFor(draft.actionType),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Text(_statusFor(draft.status),
                  style:
                      TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            draft.title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            _summary(draft),
            style: TextStyle(color: colors.onSurfaceVariant, height: 1.4),
          ),
          if (draft.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(draft.description,
                style: TextStyle(color: colors.onSurfaceVariant)),
          ],
          const SizedBox(height: 8),
          Text(
            'Agent 只生成操作草稿；确认后才会修改日历。',
            style: TextStyle(
                fontSize: 12, color: colors.onSurfaceVariant, height: 1.4),
          ),
          if (pending) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _run(widget.onCancel),
                  child: const Text('取消'),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _run(widget.onConfirm),
                  icon: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded, size: 17),
                  label: Text(_confirmLabel(draft.actionType)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  IconData _iconFor(String actionType) => switch (actionType) {
        'calendar_event_delete' => Icons.delete_outline_rounded,
        'calendar_reminder_create' => Icons.notifications_none_rounded,
        _ => Icons.event_note_outlined,
      };

  String _titleFor(String actionType) => switch (actionType) {
        'calendar_event_update' => '建议更新日历事件',
        'calendar_event_delete' => '建议删除日历事件',
        'calendar_reminder_create' => '建议添加日历提醒',
        _ => '建议创建日历事件',
      };

  String _confirmLabel(String actionType) => switch (actionType) {
        'calendar_event_update' => '确认更新',
        'calendar_event_delete' => '确认删除',
        'calendar_reminder_create' => '确认添加提醒',
        _ => '确认添加',
      };

  String _statusFor(String status) => switch (status) {
        'executed' => '已执行',
        'expired' => '已过期',
        'cancelled' => '已取消',
        'failed' => '执行失败',
        _ => '待确认',
      };

  String _summary(UserCalendarActionDraft draft) {
    final start = _formatTime(draft.startAt);
    final end = _formatTime(draft.endAt);
    final location = draft.location.isEmpty ? '' : ' · ${draft.location}';
    final reminder = draft.reminderMinutesBefore == null
        ? ''
        : ' · 提前 ${draft.reminderMinutesBefore} 分钟';
    return '${draft.allDay ? '全天' : '$start - $end'}$location$reminder';
  }

  String _formatTime(DateTime value) =>
      '${value.month}/${value.day} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
