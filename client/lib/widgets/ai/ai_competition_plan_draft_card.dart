import 'package:flutter/material.dart';

import '../../models/competition_action_draft.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';

class AiCompetitionPlanDraftCard extends StatefulWidget {
  const AiCompetitionPlanDraftCard({
    super.key,
    required this.draft,
    required this.onConfirm,
    this.onViewCompetition,
  });

  final CompetitionPlanActionDraft draft;
  final Future<void> Function()? onConfirm;
  final VoidCallback? onViewCompetition;

  @override
  State<AiCompetitionPlanDraftCard> createState() =>
      _AiCompetitionPlanDraftCardState();
}

class _AiCompetitionPlanDraftCardState
    extends State<AiCompetitionPlanDraftCard> {
  bool _busy = false;

  Future<void> _confirm() async {
    if (_busy || widget.onConfirm == null || !widget.draft.isPending) return;
    setState(() => _busy = true);
    try {
      await widget.onConfirm!();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.draft.event;
    final isPending = widget.draft.isPending && !widget.draft.isExpired;
    final statusText = switch (widget.draft.status) {
      'executed' => '已加入我的计划',
      'expired' => '建议已过期',
      'failed' => '建议已失效',
      'cancelled' => '建议已取消',
      _ => '待确认',
    };
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.surfaceSecondaryDark
            : Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.borderNormalLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.playlist_add_rounded,
                  size: 20, color: AppColors.brandPrimary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('建议加入计划',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              Text(statusText,
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondaryLight)),
            ],
          ),
          const SizedBox(height: 10),
          Text(event.title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              if (event.personalizedScore != null)
                Text('偏好匹配 ${event.personalizedScore}',
                    style: const TextStyle(fontSize: 12)),
              if (event.competitionRating.isNotEmpty)
                Text('人工评级 ${event.competitionRating}',
                    style: const TextStyle(fontSize: 12)),
              if (event.schoolRecognitionStatus.isNotEmpty)
                Text('学校认定：${_recognition(event.schoolRecognitionStatus)}',
                    style: const TextStyle(fontSize: 12)),
              if (event.registrationTimeText.isNotEmpty)
                Text('报名时间：${event.registrationTimeText}',
                    style: const TextStyle(fontSize: 12)),
            ],
          ),
          if (event.fitReasons.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text('匹配原因',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 4),
            for (final reason in event.fitReasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('· $reason',
                    style: const TextStyle(fontSize: 12, height: 1.35)),
              ),
          ],
          const SizedBox(height: 8),
          Text(
            'Agent 只解释平台现有推荐结果；不会自动报名，也不代表学校确认参赛资格。',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: widget.onViewCompetition,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('查看比赛'),
              ),
              if (isPending)
                FilledButton.icon(
                  onPressed: _busy ? null : _confirm,
                  icon: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.playlist_add_rounded, size: 17),
                  label: const Text('加入我的计划'),
                ),
              if (widget.draft.status == 'executed')
                OutlinedButton.icon(
                  onPressed: widget.onViewCompetition,
                  icon: const Icon(Icons.event_note_outlined, size: 16),
                  label: const Text('查看计划'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _recognition(String value) => switch (value) {
        'recognized' => '已认定',
        'pending' => '待确认',
        'not_recognized' => '未认定',
        _ => value,
      };
}
