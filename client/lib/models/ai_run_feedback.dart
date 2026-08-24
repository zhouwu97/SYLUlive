enum AiFeedbackRating { positive, negative }

enum AiFeedbackStatus { none, submitting, positive, negative, failed }

enum AiFeedbackReason {
  irrelevant,
  misunderstood,
  wrongData,
  tooSlow,
  actionFailed,
  privacyBoundary,
  other,
}

extension AiFeedbackReasonWire on AiFeedbackReason {
  String get wireValue => switch (this) {
        AiFeedbackReason.irrelevant => 'irrelevant',
        AiFeedbackReason.misunderstood => 'misunderstood',
        AiFeedbackReason.wrongData => 'wrong_data',
        AiFeedbackReason.tooSlow => 'too_slow',
        AiFeedbackReason.actionFailed => 'action_failed',
        AiFeedbackReason.privacyBoundary => 'privacy_boundary',
        AiFeedbackReason.other => 'other',
      };

  String get label => switch (this) {
        AiFeedbackReason.irrelevant => '答非所问',
        AiFeedbackReason.misunderstood => '理解错了',
        AiFeedbackReason.wrongData => '查错数据',
        AiFeedbackReason.tooSlow => '太慢了',
        AiFeedbackReason.actionFailed => '操作没成功',
        AiFeedbackReason.privacyBoundary => '不该访问这些信息',
        AiFeedbackReason.other => '其他',
      };

  String get failureReasonValue => switch (this) {
        AiFeedbackReason.irrelevant => 'answer_wrong',
        AiFeedbackReason.misunderstood => 'clarification_wrong',
        AiFeedbackReason.wrongData => 'capability_wrong',
        AiFeedbackReason.tooSlow => 'latency_too_high',
        AiFeedbackReason.actionFailed => 'action_wrong',
        AiFeedbackReason.privacyBoundary => 'privacy_boundary',
        AiFeedbackReason.other => 'other',
      };
}

class AiRunFeedback {
  const AiRunFeedback({
    required this.rating,
    this.reason,
    this.note = '',
  });

  final AiFeedbackRating rating;
  final AiFeedbackReason? reason;
  final String note;
}
