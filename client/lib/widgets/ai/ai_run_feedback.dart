import 'package:flutter/material.dart';

import '../../models/ai_run_feedback.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_radius.dart';

class AiRunFeedbackButtons extends StatelessWidget {
  const AiRunFeedbackButtons({
    super.key,
    required this.status,
    required this.onSubmit,
    this.errorMessage = '',
  });

  final AiFeedbackStatus status;
  final Future<void> Function(AiRunFeedback feedback) onSubmit;
  final String errorMessage;

  Future<void> _showNegativeSheet(BuildContext context) async {
    var reason = AiFeedbackReason.other;
    final noteController = TextEditingController();
    final feedback = await showModalBottomSheet<AiRunFeedback>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setState) {
          final colors = Theme.of(context).colorScheme;
          return Container(
            padding: EdgeInsets.fromLTRB(
              20,
              18,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRadius.sheet),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('哪里需要改进？', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  '选择一个最符合的原因，帮助我们改进回答质量。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: AiFeedbackReason.values.map((item) {
                    return ChoiceChip(
                      label: Text(item.label),
                      selected: reason == item,
                      onSelected: (_) => setState(() => reason = item),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: noteController,
                  maxLength: 200,
                  maxLines: 3,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    labelText: '补充说明（可选）',
                    hintText: '请不要填写身份证号、成绩等敏感信息',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(
                        AiRunFeedback(
                          rating: AiFeedbackRating.negative,
                          reason: reason,
                          note: noteController.text,
                        ),
                      ),
                      child: const Text('提交反馈'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
    noteController.dispose();
    if (feedback != null && context.mounted) await onSubmit(feedback);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final busy = status == AiFeedbackStatus.submitting;
    final submitted = status == AiFeedbackStatus.positive ||
        status == AiFeedbackStatus.negative;
    final failed = status == AiFeedbackStatus.failed;
    return AnimatedSwitcher(
      duration: AppMotion.duration(context, AppMotion.fast),
      child: submitted
          ? Semantics(
              key: const ValueKey('ai-feedback-submitted'),
              liveRegion: true,
              label: '反馈已记录',
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline_rounded,
                        size: 16, color: colors.primary),
                    const SizedBox(width: 6),
                    Text('反馈已记录', style: Theme.of(context).textTheme.labelMedium),
                  ],
                ),
              ),
            )
          : Row(
              key: const ValueKey('ai-feedback-actions'),
              children: [
                _FeedbackButton(
                  label: '有帮助',
                  icon: Icons.thumb_up_outlined,
                  onPressed: busy
                      ? null
                      : () => onSubmit(const AiRunFeedback(
                            rating: AiFeedbackRating.positive,
                          )),
                ),
                _FeedbackButton(
                  label: '没帮助',
                  icon: Icons.thumb_down_outlined,
                  onPressed: busy ? null : () => _showNegativeSheet(context),
                ),
                if (busy) ...[
                  const SizedBox(width: 6),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
                if (failed && errorMessage.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      errorMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.error, fontSize: 11),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _FeedbackButton extends StatelessWidget {
  const _FeedbackButton({required this.label, required this.icon, this.onPressed});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
      ),
    );
  }
}
