import 'ai_source.dart';
import 'competition_action_draft.dart';
import 'user_calendar.dart';
import 'ai_personal_data_evidence.dart';
import 'ai_run_feedback.dart';

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
  final List<UserCalendarActionDraft> calendarActionDrafts;
  final AiFeedbackStatus feedbackStatus;
  final AiFeedbackReason? feedbackReason;
  final String feedbackError;
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
    this.calendarActionDrafts = const [],
    this.feedbackStatus = AiFeedbackStatus.none,
    this.feedbackReason,
    this.feedbackError = '',
  });

  AiChatMessage copyWith({
    String? content,
    AiMessageStatus? status,
    List<AiSource>? sources,
    AiSourceRecoveryState? sourceRecoveryState,
    List<AiPersonalDataEvidence>? personalDataEvidence,
    List<CompetitionPlanActionDraft>? actionDrafts,
    List<UserCalendarActionDraft>? calendarActionDrafts,
    AiFeedbackStatus? feedbackStatus,
    AiFeedbackReason? feedbackReason,
    String? feedbackError,
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
      calendarActionDrafts: calendarActionDrafts ?? this.calendarActionDrafts,
      feedbackStatus: feedbackStatus ?? this.feedbackStatus,
      feedbackReason: feedbackReason ?? this.feedbackReason,
      feedbackError: feedbackError ?? this.feedbackError,
    );
  }
}
