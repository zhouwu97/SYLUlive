// MessageSendState 陌生人私信发送状态，对应后端 /api/messages/:id/send-state
class MessageSendState {
  final bool canSend;
  final String? reason;
  final bool firstContactUsed;
  final bool targetFollowsMe;
  final bool targetReplied;

  const MessageSendState({
    required this.canSend,
    this.reason,
    this.firstContactUsed = false,
    this.targetFollowsMe = false,
    this.targetReplied = false,
  });

  factory MessageSendState.fromJson(Map<String, dynamic> json) {
    return MessageSendState(
      canSend: json['can_send'] == true,
      reason: json['reason'] as String?,
      firstContactUsed: json['first_contact_used'] == true,
      targetFollowsMe: json['target_follows_me'] == true,
      targetReplied: json['target_replied'] == true,
    );
  }

  /// 拒绝时使用的统一文案
  static const blockedReason = 'message_requires_reply_or_follow';
  static const levelBlockedReason = 'level_too_low';

  bool get isBlocked => !canSend;
  bool get isLevelBlocked => !canSend && reason == levelBlockedReason;
}