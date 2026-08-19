// MessageSendState 陌生人私信发送状态，对应后端 /api/messages/:id/send-state
class MessageSendState {
  final bool canSend;
  final String? reason;
  final bool firstContactUsed;
  final bool targetFollowsMe;
  final bool targetReplied;
  final bool hasFirstContactDetails;

  const MessageSendState({
    required this.canSend,
    this.reason,
    this.firstContactUsed = false,
    this.targetFollowsMe = false,
    this.targetReplied = false,
    this.hasFirstContactDetails = false,
  });

  factory MessageSendState.fromJson(Map<String, dynamic> json) {
    return MessageSendState(
      canSend: json['can_send'] == true,
      reason: json['reason'] as String?,
      firstContactUsed: json['first_contact_used'] == true,
      targetFollowsMe: json['target_follows_me'] == true,
      targetReplied: json['target_replied'] == true,
      // 老服务端可能只返回 can_send；缺少完整字段时不能误判为陌生人限制。
      hasFirstContactDetails: json.containsKey('first_contact_used') &&
          json.containsKey('target_follows_me') &&
          json.containsKey('target_replied'),
    );
  }

  /// 拒绝时使用的统一文案
  static const blockedReason = 'message_requires_reply_or_follow';

  bool get isBlocked => !canSend;

  /// 当前响应明确表示可以使用一次陌生人首条私信额度。
  bool get canUseFirstContactAllowance =>
      canSend &&
      hasFirstContactDetails &&
      !firstContactUsed &&
      !targetFollowsMe &&
      !targetReplied;
}
