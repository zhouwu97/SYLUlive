import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../models/ai_chat_message.dart';
import '../../models/ai_personal_data_evidence.dart';
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
                _CompactEvidenceTag(
                  evidence: message.personalDataEvidence,
                ),
              if (!isUser &&
                  message.sourceRecoveryState == AiSourceRecoveryState.failed &&
                  citation.hasUnresolvedChunks)
                _SourceRecoveryNotice(onRetry: onRetrySources),
              if (!isUser && citation.sources.isNotEmpty)
                _CompactSourceTags(
                  sources: citation.sources,
                  loadSourceContent: loadSourceContent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactEvidenceTag extends StatelessWidget {
  const _CompactEvidenceTag({required this.evidence});

  final List<AiPersonalDataEvidence> evidence;

  @override
  Widget build(BuildContext context) {
    return _CompactSourceTag(
      icon: Icons.verified_user_outlined,
      label: '个人数据来源',
      onTap: () => showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: SingleChildScrollView(
            child: AiCampusEvidenceCard(
              evidence: evidence,
              initiallyExpanded: true,
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactSourceTags extends StatelessWidget {
  const _CompactSourceTags({
    required this.sources,
    this.loadSourceContent,
  });

  final List<AiSource> sources;
  final Future<AiSourceContent> Function(int chunkId)? loadSourceContent;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final source in sources)
          _CompactSourceTag(
            icon: switch (source.type) {
              AiSourceType.schedule => Icons.calendar_month_rounded,
              AiSourceType.competitionCatalog => Icons.emoji_events_outlined,
              AiSourceType.competitionEvidence => Icons.fact_check_outlined,
              AiSourceType.policy => Icons.description_outlined,
            },
            label: source.title,
            onTap: () => showModalBottomSheet<void>(
              context: context,
              useSafeArea: true,
              isScrollControlled: true,
              builder: (_) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: SingleChildScrollView(
                  child: AiSourceCard(
                    source: source,
                    loadContent: loadSourceContent,
                    initiallyExpanded: true,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CompactSourceTag extends StatelessWidget {
  const _CompactSourceTag({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        button: true,
        label: '查看来源：$label',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              constraints: const BoxConstraints(minHeight: 36, maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: colors.primary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: null,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 15,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
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
