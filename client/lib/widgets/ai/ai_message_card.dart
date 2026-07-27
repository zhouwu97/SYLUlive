import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../models/ai_chat_message.dart';
import '../../models/ai_source.dart';
import '../../models/competition_action_draft.dart';
import '../campus/campus_theme.dart';
import 'ai_competition_plan_draft_card.dart';
import 'ai_source_card.dart';

class AiMessageCard extends StatelessWidget {
  final AiChatMessage message;
  final Future<void> Function(CompetitionPlanActionDraft draft)? onConfirmDraft;
  final void Function(int eventId)? onViewCompetition;
  final Future<AiSourceContent> Function(int chunkId)? loadSourceContent;
  const AiMessageCard({
    super.key,
    required this.message,
    this.onConfirmDraft,
    this.onViewCompetition,
    this.loadSourceContent,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == AiMessageRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: isUser ? 0.72 : 0.88,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isUser ? CampusTheme.primary : Colors.white,
            borderRadius: BorderRadius.circular(isUser ? 16 : 18),
            border: isUser ? null : Border.all(color: CampusTheme.softBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isUser)
                Text(
                  message.content,
                  style: const TextStyle(color: Colors.white, height: 1.45),
                )
              else
                MarkdownBody(
                  data: sanitizeAiCitationDisplay(message.content),
                  selectable: true,
                  styleSheet: MarkdownStyleSheet(
                    p: const TextStyle(
                      color: CampusTheme.text,
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
              for (final source in message.sources)
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
  return content.replaceAll(
    RegExp(r'\[chunk:[^\]\s]*(?:\]|$)', caseSensitive: false),
    '[来源]',
  );
}
