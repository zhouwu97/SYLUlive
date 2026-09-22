import 'dart:convert';

class FeedbackTicket {
  final int id;
  final String ticketNo;
  final int userId;
  final String type; // 'bug', 'suggestion', 'other'
  final String title;
  final String description;
  final String? stepsToReproduce;
  final String? actualResult;
  final String? expectedResult;
  final String status;
  final String? statusNote;
  final String priority;
  final int? assigneeAdminId;
  final String? assigneeAdminName;
  final bool adminViewed;
  final DateTime? adminFirstViewedAt;
  final int userUnreadCount;
  final String? appVersion;
  final String? buildNumber;
  final String? deviceModel;
  final String? osVersion;
  final String? networkType;
  final String? currentRoute;
  final String? diagnosticsJson;
  final String? latestReplySnippet;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? resolvedAt;
  final DateTime? closedAt;
  final List<FeedbackAttachment> attachments;

  FeedbackTicket({
    required this.id,
    required this.ticketNo,
    required this.userId,
    required this.type,
    required this.title,
    required this.description,
    this.stepsToReproduce,
    this.actualResult,
    this.expectedResult,
    required this.status,
    this.statusNote,
    this.priority = 'P2',
    this.assigneeAdminId,
    this.assigneeAdminName,
    this.adminViewed = false,
    this.adminFirstViewedAt,
    this.userUnreadCount = 0,
    this.appVersion,
    this.buildNumber,
    this.deviceModel,
    this.osVersion,
    this.networkType,
    this.currentRoute,
    this.diagnosticsJson,
    this.latestReplySnippet,
    required this.createdAt,
    required this.updatedAt,
    this.resolvedAt,
    this.closedAt,
    this.attachments = const [],
  });

  factory FeedbackTicket.fromJson(Map<String, dynamic> json) {
    return FeedbackTicket(
      id: json['id'] as int? ?? 0,
      ticketNo: json['ticket_no'] as String? ?? '',
      userId: json['user_id'] as int? ?? 0,
      type: json['type'] as String? ?? 'bug',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      stepsToReproduce: json['steps_to_reproduce'] as String?,
      actualResult: json['actual_result'] as String?,
      expectedResult: json['expected_result'] as String?,
      status: json['status'] as String? ?? 'pending',
      statusNote: json['status_note'] as String?,
      priority: json['priority'] as String? ?? 'P2',
      assigneeAdminId: json['assignee_admin_id'] as int?,
      assigneeAdminName: json['assignee_admin'] is Map
          ? (json['assignee_admin']['nickname'] as String?)
          : null,
      adminViewed: json['admin_viewed'] as bool? ?? false,
      adminFirstViewedAt: json['admin_first_viewed_at'] != null
          ? DateTime.tryParse(json['admin_first_viewed_at'] as String)
          : null,
      userUnreadCount: json['user_unread_count'] as int? ?? 0,
      appVersion: json['app_version'] as String?,
      buildNumber: json['build_number'] as String?,
      deviceModel: json['device_model'] as String?,
      osVersion: json['os_version'] as String?,
      networkType: json['network_type'] as String?,
      currentRoute: json['current_route'] as String?,
      diagnosticsJson: json['diagnostics_json'] as String?,
      latestReplySnippet: json['latest_reply_snippet'] as String?,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
          DateTime.now(),
      resolvedAt: json['resolved_at'] != null
          ? DateTime.tryParse(json['resolved_at'] as String)
          : null,
      closedAt: json['closed_at'] != null
          ? DateTime.tryParse(json['closed_at'] as String)
          : null,
      attachments: (json['attachments'] as List<dynamic>?)
              ?.map(
                  (e) => FeedbackAttachment.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  String get typeLabel {
    switch (type) {
      case 'bug':
        return '问题反馈';
      case 'suggestion':
        return '功能建议';
      default:
        return '其他';
    }
  }

  String get statusDisplayName {
    return statusLabel(isAdmin: false);
  }

  String get adminStatusDisplayName {
    return statusLabel(isAdmin: true);
  }

  String statusLabel({required bool isAdmin}) {
    switch (status) {
      case 'pending':
        return '待受理';
      case 'accepted':
        return '已受理';
      case 'waiting_user':
        return isAdmin ? '待用户补充' : '待你补充';
      case 'investigating':
        return '定位中';
      case 'fixing':
        return '修复中';
      case 'testing':
        return '测试中';
      case 'resolved':
        return '已解决';
      case 'closed':
        return '已关闭';
      default:
        return status;
    }
  }
}

class FeedbackInitialSubmission {
  final int messageId;
  final String senderType;
  final int senderId;
  final String content;
  final DateTime createdAt;
  final List<FeedbackAttachment> attachments;

  const FeedbackInitialSubmission({
    required this.messageId,
    required this.senderType,
    required this.senderId,
    required this.content,
    required this.createdAt,
    this.attachments = const [],
  });

  factory FeedbackInitialSubmission.fromJson(Map<String, dynamic> json) {
    return FeedbackInitialSubmission(
      messageId: json['message_id'] as int? ?? 0,
      senderType: json['sender_type'] as String? ?? 'user',
      senderId: json['sender_id'] as int? ?? 0,
      content: json['content'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      attachments: (json['attachments'] as List<dynamic>?)
              ?.map(
                  (e) => FeedbackAttachment.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

class FeedbackMessage {
  final int id;
  final int ticketId;
  final String senderType; // 'user', 'admin', 'system'
  final int senderId;
  final String
      messageType; // 'initial_submission', 'text', 'image', 'system', 'status_change', 'request_info', 'internal_note'
  final String content;
  final String? metadataJson;
  final bool visibleToUser;
  final DateTime createdAt;
  final List<FeedbackAttachment> attachments;

  FeedbackMessage({
    required this.id,
    required this.ticketId,
    required this.senderType,
    required this.senderId,
    required this.messageType,
    required this.content,
    this.metadataJson,
    this.visibleToUser = true,
    required this.createdAt,
    this.attachments = const [],
  });

  factory FeedbackMessage.fromJson(Map<String, dynamic> json) {
    return FeedbackMessage(
      id: json['id'] as int? ?? 0,
      ticketId: json['ticket_id'] as int? ?? 0,
      senderType: json['sender_type'] as String? ?? 'user',
      senderId: json['sender_id'] as int? ?? 0,
      messageType: json['message_type'] as String? ?? 'text',
      content: json['content'] as String? ?? '',
      metadataJson: json['metadata_json'] as String?,
      visibleToUser: json['visible_to_user'] as bool? ?? true,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      attachments: (json['attachments'] as List<dynamic>?)
              ?.map(
                  (e) => FeedbackAttachment.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  bool get isUser => senderType == 'user';
  bool get isAdmin => senderType == 'admin';
  bool get isSystem => senderType == 'system';
  bool get isInternalNote => messageType == 'internal_note';
  bool get isRequestInfo => messageType == 'request_info';
  bool get isStatusChange => messageType == 'status_change';
}

class FeedbackAttachment {
  final int id;
  final int ticketId;
  final int? messageId;
  final int fileId;
  final String? url;
  final DateTime createdAt;

  FeedbackAttachment({
    required this.id,
    required this.ticketId,
    this.messageId,
    required this.fileId,
    this.url,
    required this.createdAt,
  });

  factory FeedbackAttachment.fromJson(Map<String, dynamic> json) {
    String? fileUrl;
    if (json['file'] is Map) {
      fileUrl = json['file']['path'] as String?;
    }
    return FeedbackAttachment(
      id: json['id'] as int? ?? 0,
      ticketId: json['ticket_id'] as int? ?? 0,
      messageId: json['message_id'] as int?,
      fileId: json['file_id'] as int? ?? 0,
      url: fileUrl,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class FeedbackStatusHistory {
  final int id;
  final int ticketId;
  final int operatorId;
  final String operatorType;
  final String oldStatus;
  final String newStatus;
  final String note;
  final DateTime createdAt;

  FeedbackStatusHistory({
    required this.id,
    required this.ticketId,
    required this.operatorId,
    required this.operatorType,
    required this.oldStatus,
    required this.newStatus,
    required this.note,
    required this.createdAt,
  });

  factory FeedbackStatusHistory.fromJson(Map<String, dynamic> json) {
    return FeedbackStatusHistory(
      id: json['id'] as int? ?? 0,
      ticketId: json['ticket_id'] as int? ?? 0,
      operatorId: json['operator_id'] as int? ?? 0,
      operatorType: json['operator_type'] as String? ?? 'system',
      oldStatus: json['old_status'] as String? ?? '',
      newStatus: json['new_status'] as String? ?? '',
      note: json['note'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// 待发送工单消息的请求指纹。
///
/// 内容、附件、可见范围任一变化都算**新的一条消息**。失败后用户改措辞、
/// 补图片、把"用户可见"切成内部备注，都不能继续用上一条的幂等键，
/// 否则服务端按不同请求体回 idempotency_key_reused，用户卡在"改了也提交不了"。
String feedbackMessageFingerprint({
  required String content,
  required List<int>? imageIds,
  required bool visibleToUser,
}) {
  return jsonEncode(<String, dynamic>{
    'content': content,
    'image_ids': imageIds,
    'visible_to_user': visibleToUser,
  });
}
