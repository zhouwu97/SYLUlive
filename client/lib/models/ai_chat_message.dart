import 'ai_source.dart';
import 'competition_action_draft.dart';
import 'ai_personal_data_evidence.dart';

enum AiMessageRole { user, assistant }

enum AiMessageStatus { pending, streaming, completed, failed }

enum AiSourceRecoveryState { notNeeded, loading, loaded, failed }

class AiChatMessage {
  final String id;
  final String requestId;
  final AiMessageRole role;
  final String content;
  final AiMessageStatus status;
  final List<AiSource> sources;
  final AiSourceRecoveryState sourceRecoveryState;
  final List<AiPersonalDataEvidence> personalDataEvidence;
  final List<CompetitionPlanActionDraft> actionDrafts;
  final DateTime createdAt;

  const AiChatMessage({
    required this.id,
    required this.requestId,
    required this.role,
    required this.content,
    required this.status,
    required this.createdAt,
    this.sources = const [],
    this.sourceRecoveryState = AiSourceRecoveryState.notNeeded,
    this.personalDataEvidence = const [],
    this.actionDrafts = const [],
  });

  AiChatMessage copyWith({
    String? content,
    AiMessageStatus? status,
    List<AiSource>? sources,
    AiSourceRecoveryState? sourceRecoveryState,
    List<AiPersonalDataEvidence>? personalDataEvidence,
    List<CompetitionPlanActionDraft>? actionDrafts,
  }) {
    return AiChatMessage(
      id: id,
      requestId: requestId,
      role: role,
      content: content ?? this.content,
      status: status ?? this.status,
      createdAt: createdAt,
      sources: sources ?? this.sources,
      sourceRecoveryState: sourceRecoveryState ?? this.sourceRecoveryState,
      personalDataEvidence: personalDataEvidence ?? this.personalDataEvidence,
      actionDrafts: actionDrafts ?? this.actionDrafts,
    );
  }
}
