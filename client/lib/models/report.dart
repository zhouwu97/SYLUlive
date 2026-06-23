import 'user.dart';

// 公告模型
class Announcement {
  final int id;
  final String title;
  final String content;
  final bool isPinned;
  final int createdBy;
  final User? creator;
  final DateTime createdAt;

  Announcement({
    required this.id,
    required this.title,
    required this.content,
    this.isPinned = false,
    required this.createdBy,
    this.creator,
    required this.createdAt,
  });

  factory Announcement.fromJson(Map<String, dynamic> json) {
    return Announcement(
      id: json['id'] ?? 0,
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      isPinned: json['is_pinned'] ?? false,
      createdBy: json['created_by'] ?? 0,
      creator: json['creator'] != null ? User.fromJson(json['creator']) : null,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}

// 举报模型
class Report {
  final int id;
  final int reporterId;
  final String targetType;
  final int targetId;
  final String reason;
  final String status;
  final int? handlerId;
  final String result;
  final String deleteReason;
  final DateTime createdAt;
  final DateTime? handledAt;
  final User? reporter;
  final User? handler;

  Report({
    required this.id,
    required this.reporterId,
    required this.targetType,
    required this.targetId,
    required this.reason,
    this.status = 'pending',
    this.handlerId,
    this.result = '',
    this.deleteReason = '',
    required this.createdAt,
    this.handledAt,
    this.reporter,
    this.handler,
  });

  factory Report.fromJson(Map<String, dynamic> json) {
    return Report(
      id: json['id'] ?? 0,
      reporterId: json['reporter_id'] ?? 0,
      targetType: json['target_type'] ?? '',
      targetId: json['target_id'] ?? 0,
      reason: json['reason'] ?? '',
      status: json['status'] ?? 'pending',
      handlerId: json['handler_id'],
      result: json['result'] ?? '',
      deleteReason: json['delete_reason'] ?? '',
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      handledAt: json['handled_at'] != null
          ? DateTime.tryParse(json['handled_at'])
          : null,
      reporter: json['reporter'] != null
          ? User.fromJson(json['reporter'])
          : null,
      handler: json['handler'] != null ? User.fromJson(json['handler']) : null,
    );
  }
}

// 申诉模型
class Appeal {
  final int id;
  final int postId;
  final int appellantId;
  final int adminId;
  final String adminReason;
  final String status;
  final String result;
  final DateTime createdAt;
  final DateTime? closedAt;
  final User? appellant;
  final User? admin;

  Appeal({
    required this.id,
    required this.postId,
    required this.appellantId,
    required this.adminId,
    required this.adminReason,
    this.status = 'pending',
    this.result = '',
    required this.createdAt,
    this.closedAt,
    this.appellant,
    this.admin,
  });

  factory Appeal.fromJson(Map<String, dynamic> json) {
    return Appeal(
      id: json['id'] ?? 0,
      postId: json['post_id'] ?? 0,
      appellantId: json['appellant_id'] ?? 0,
      adminId: json['admin_id'] ?? 0,
      adminReason: json['admin_reason'] ?? '',
      status: json['status'] ?? 'pending',
      result: json['result'] ?? '',
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      closedAt: json['closed_at'] != null
          ? DateTime.tryParse(json['closed_at'])
          : null,
      appellant: json['appellant'] != null
          ? User.fromJson(json['appellant'])
          : null,
      admin: json['admin'] != null ? User.fromJson(json['admin']) : null,
    );
  }
}

// 申诉投票模型
class AppealVote {
  final int id;
  final int appealId;
  final int voterId;
  final String vote;
  final String comment;
  final DateTime createdAt;
  final User? voter;

  AppealVote({
    required this.id,
    required this.appealId,
    required this.voterId,
    this.vote = '',
    this.comment = '',
    required this.createdAt,
    this.voter,
  });

  factory AppealVote.fromJson(Map<String, dynamic> json) {
    return AppealVote(
      id: json['id'] ?? 0,
      appealId: json['appeal_id'] ?? 0,
      voterId: json['voter_id'] ?? 0,
      vote: json['vote'] ?? '',
      comment: json['comment'] ?? '',
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      voter: json['voter'] != null ? User.fromJson(json['voter']) : null,
    );
  }
}

// 邀请模型
class Invitation {
  final int id;
  final int userId;
  final int inviterId;
  final String status;
  final DateTime createdAt;
  final DateTime? acceptedAt;
  final User? user;
  final User? inviter;

  Invitation({
    required this.id,
    required this.userId,
    required this.inviterId,
    this.status = 'pending',
    required this.createdAt,
    this.acceptedAt,
    this.user,
    this.inviter,
  });

  factory Invitation.fromJson(Map<String, dynamic> json) {
    return Invitation(
      id: json['id'] ?? 0,
      userId: json['user_id'] ?? 0,
      inviterId: json['inviter_id'] ?? 0,
      status: json['status'] ?? 'pending',
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      acceptedAt: json['accepted_at'] != null
          ? DateTime.tryParse(json['accepted_at'])
          : null,
      user: json['user'] != null ? User.fromJson(json['user']) : null,
      inviter: json['inviter'] != null ? User.fromJson(json['inviter']) : null,
    );
  }
}
