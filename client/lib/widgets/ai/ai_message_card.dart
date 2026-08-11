import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../models/ai_chat_message.dart';
import '../../models/ai_source.dart';
import '../../models/competition_action_draft.dart';
import '../../utils/ai_citation_mapper.dart';
import 'ai_competition_plan_draft_card.dart';
import 'ai_evidence_card.dart';
import 'ai_source_card.dart';
import '../campus/campus_theme.dart';

class AiMessageCard extends StatelessWidget {
  final AiChatMessage message;
  final Future<void> Function(CompetitionPlanActionDraft draft)? onConfirmDraft;
  final void Function(int eventId)? onViewCompetition;
  final Future<AiSourceContent> Function(int chunkId)? loadSourceContent;
  final VoidCallback? onRetrySources;
  const AiMessageCard({
    super.key,
    required this.message,
    this.onConfirmDraft,
    this.onViewCompetition,
    this.loadSourceContent,
    this.onRetrySources,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == AiMessageRole.user;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final assistantSurface =
        isDark ? colors.primaryContainer : CampusTheme.primaryLight;
    final assistantBorder =
        isDark ? Colors.white.withValues(alpha: 0.12) : CampusTheme.border;
    final citation = resolveMessageSources(
      content: message.content,
      sources: message.sources,
    );
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: isUser ? 0.72 : 0.88,
        child: Container(
          key: ValueKey('ai-message-card-${message.id}'),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isUser ? colors.primary : assistantSurface,
            borderRadius: BorderRadius.circular(isUser ? 16 : 18),
            border: isUser ? null : Border.all(color: assistantBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isUser)
                Text(
                  message.content,
                  style: TextStyle(color: colors.onPrimary, height: 1.45),
                )
              else
                MarkdownBody(
                  data: citation.content,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet(
                    p: TextStyle(
                      color: colors.onSurface,
                      fontSize: 15,
                      height: 1.55,
                    ),
                  ),
                ),
              for (final draft in message.actionDrafts)
                AiCompetitionPlanDraftCard(
                  draft: draft,
                  onConfirm: onConfirmDraft == null
                      ? null
                      : () => onConfirmDraft!(draft),
                  onViewCompetition: onViewCompetition == null
                      ? null
                      : () => onViewCompetition!(draft.event.id),
                ),
              if (!isUser && message.personalDataEvidence.isNotEmpty)
                AiCampusEvidenceCard(evidence: message.personalDataEvidence),
              if (!isUser &&
                  message.sourceRecoveryState == AiSourceRecoveryState.failed &&
                  citation.hasUnresolvedChunks)
                _SourceRecoveryNotice(onRetry: onRetrySources),
              for (final source in citation.sources)
                AiSourceCard(source: source, loadContent: loadSourceContent),
            ],
          ),
        ),
      ),
    );
  }
}

/// 旧链路若返回内部 chunk 引用，展示层只保留“来源”语义，不暴露内部 ID。
String sanitizeAiCitationDisplay(String content) {
  return resolveMessageSources(content: content, sources: const []).content;
}

class _SourceRecoveryNotice extends StatelessWidget {
  const _SourceRecoveryNotice({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: colors.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '来源恢复失败，引用暂时不可用',
              style: TextStyle(color: colors.error, fontSize: 12),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: const Text('重试'),
            ),
        ],
      ),
    );
  }
}
