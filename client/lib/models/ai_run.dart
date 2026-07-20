class AiRun {
  final String id;
  final String conversationId;
  final String state;
  final int lastEventSeq;
  final String answerCheckpoint;
  final String errorCode;
  final DateTime? createdAt;
  final DateTime? completedAt;

  const AiRun({
    required this.id,
    required this.conversationId,
    required this.state,
    required this.lastEventSeq,
    this.answerCheckpoint = '',
    this.errorCode = '',
    this.createdAt,
    this.completedAt,
  });

  factory AiRun.fromJson(Map<String, dynamic> json) {
    return AiRun(
      id: json['id']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
      state: json['state']?.toString() ?? '',
      lastEventSeq: _asInt(json['last_event_seq']),
      answerCheckpoint: json['answer_checkpoint']?.toString() ?? '',
      errorCode: json['error_code']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal(),
      completedAt:
          DateTime.tryParse(json['completed_at']?.toString() ?? '')?.toLocal(),
    );
  }
}

class AiRunCreation {
  final AiRun run;
  final bool duplicate;

  const AiRunCreation({required this.run, required this.duplicate});
}

int _asInt(dynamic value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
