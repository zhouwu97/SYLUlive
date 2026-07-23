import 'competition.dart';
import '../features/ai_runtime/skills/personal_skill.dart';

class CompetitionPlanActionDraft implements SkillActionArtifact {
  CompetitionPlanActionDraft({
    required this.id,
    required this.actionType,
    required this.status,
    required this.expiresAt,
    required this.event,
    this.planItemId,
  });

  factory CompetitionPlanActionDraft.fromJson(Map<String, dynamic> json) {
    final rawEvent = json['event'];
    if (rawEvent is! Map) {
      throw const FormatException('竞赛操作草稿缺少赛事预览');
    }
    final expires = DateTime.tryParse('${json['expires_at'] ?? ''}');
    if (expires == null) {
      throw const FormatException('竞赛操作草稿过期时间无效');
    }
    return CompetitionPlanActionDraft(
      id: (json['id'] as num?)?.toInt() ?? 0,
      actionType: '${json['action_type'] ?? ''}',
      status: '${json['status'] ?? ''}',
      expiresAt: expires,
      planItemId: (json['plan_item_id'] as num?)?.toInt(),
      event: CompetitionEvent.fromJson(
        Map<String, dynamic>.from(rawEvent),
      ),
    );
  }

  final int id;
  final String actionType;
  final String status;
  final DateTime expiresAt;
  final int? planItemId;
  final CompetitionEvent event;

  bool get isPending => status == 'pending';
  bool get isExpired => status == 'expired' || !expiresAt.isAfter(DateTime.now());

  CompetitionPlanActionDraft copyWith({
    String? status,
    DateTime? expiresAt,
    int? planItemId,
    CompetitionEvent? event,
  }) =>
      CompetitionPlanActionDraft(
        id: id,
        actionType: actionType,
        status: status ?? this.status,
        expiresAt: expiresAt ?? this.expiresAt,
        planItemId: planItemId ?? this.planItemId,
        event: event ?? this.event,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'action_type': actionType,
        'status': status,
        'expires_at': expiresAt.toUtc().toIso8601String(),
        if (planItemId != null) 'plan_item_id': planItemId,
        'event': <String, dynamic>{
          'id': event.id,
          'title': event.title,
          'personalized_score': event.personalizedScore,
          'recommendation_tier': event.recommendationTier,
          'fit_reasons': event.fitReasons,
          'competition_rating': event.competitionRating,
          'manual_rating': event.manualRating,
          'school_recognition_status': event.schoolRecognitionStatus,
          'school_recognition_grade': event.schoolRecognitionGrade,
          'time_status': event.timeStatus,
          'registration_time_text': event.registrationTimeText,
        },
      };
}
