import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../models/ai_chat_message.dart';
import '../../models/competition_action_draft.dart';
import '../../models/ai_source.dart';
import '../../models/user_calendar.dart';
import '../../models/ai_run_feedback.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_radius.dart';
import '../../utils/ai_citation_mapper.dart';
import 'ai_calendar_action_draft_card.dart';
import 'ai_competition_plan_draft_card.dart';
import 'ai_source_chips.dart';
import 'ai_run_feedback.dart' as feedback_widgets;

class AiMessageCard extends StatelessWidget {
  const AiMessageCard({
    super.key,
    required this.message,
    this.onConfirmDraft,
    this.onConfirmCalendarDraft,
    this.onCancelCalendarDraft,
    this.onViewCompetition,
    this.loadSourceContent,
    this.onRetrySources,
    this.onFeedback,
    this.assistantLabel = '校园 Agent',
  });

  final AiChatMessage message;
  final Future<void> Function(CompetitionPlanActionDraft draft)? onConfirmDraft;
  final Future<void> Function(UserCalendarActionDraft draft)?
      onConfirmCalendarDraft;
  final Future<void> Function(UserCalendarActionDraft draft)?
      onCancelCalendarDraft;
  final void Function(int eventId)? onViewCompetition;
  final Future<AiSourceContent> Function(int chunkId)? loadSourceContent;
  final VoidCallback? onRetrySources;
  final Future<void> Function(AiRunFeedback feedback)? onFeedback;
  final String assistantLabel;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == AiMessageRole.user;
    final colors = Theme.of(context).colorScheme;
    final citation = resolveMessageSources(
      content: message.content,
      sources: message.sources,
    );

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: 0.78,
          child: Container(
            key: ValueKey('ai-message-card-${message.id}'),
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Text(
              message.content,
              style: TextStyle(
                color: colors.onPrimary,
                fontSize: 14.5,
                height: 1.45,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      key: ValueKey('ai-message-card-${message.id}'),
      margin: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 25,
                height: 25,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.brandSurfaceLight,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 14,
                  color: AppColors.brandPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                assistantLabel,
                style: const TextStyle(
                  color: AppColors.textSecondaryLight,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          MarkdownBody(
            data: citation.content,
            selectable: true,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(
                color: colors.onSurface,
                fontSize: 15,
                height: 1.64,
              ),
              listBullet: TextStyle(color: colors.onSurface, fontSize: 15),
              strong: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          for (final draft in message.actionDrafts)
            AiCompetitionPlanDraftCard(
              draft: draft,
              onConfirm:
                  onConfirmDraft == null ? null : () => onConfirmDraft!(draft),
              onViewCompetition: onViewCompetition == null
                  ? null
                  : () => onViewCompetition!(draft.event.id),
            ),
          for (final draft in message.calendarActionDrafts)
            AiCalendarActionDraftCard(
              draft: draft,
              onConfirm: onConfirmCalendarDraft == null
                  ? null
                  : () => onConfirmCalendarDraft!(draft),
              onCancel: onCancelCalendarDraft == null
                  ? null
                  : () => onCancelCalendarDraft!(draft),
            ),
          AiSourceChips(
            sources: citation.sources,
            evidence: message.personalDataEvidence,
            loadSourceContent: loadSourceContent,
          ),
          if (onFeedback != null &&
              message.status == AiMessageStatus.completed &&
              message.content.trim().isNotEmpty)
            feedback_widgets.AiRunFeedbackButtons(
              status: message.feedbackStatus,
              errorMessage: message.feedbackError,
              onSubmit: onFeedback!,
            ),
          if (message.sourceRecoveryState == AiSourceRecoveryState.failed &&
              citation.hasUnresolvedChunks)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '来源恢复失败，引用暂时不可用',
                      style: TextStyle(color: AppColors.warning, fontSize: 12),
                    ),
                  ),
                  if (onRetrySources != null)
                    TextButton(
                        onPressed: onRetrySources, child: const Text('重试')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 兼容旧链路的展示清洗入口，不暴露内部 chunk ID。
String sanitizeAiCitationDisplay(String content) {
  return resolveMessageSources(content: content, sources: const []).content;
}
