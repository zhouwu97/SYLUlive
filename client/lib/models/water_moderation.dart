import 'water_moderator.dart';

/// 版块内局部置顶
class WaterSectionPin {
  final int id;
  final int sectionId;
  final int postId;
  final int pinnedBy;
  final int weight;
  final String reason;
  final DateTime? pinnedUntil;
  final String status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const WaterSectionPin({
    this.id = 0,
    this.sectionId = 0,
    this.postId = 0,
    this.pinnedBy = 0,
    this.weight = 0,
    this.reason = '',
    this.pinnedUntil,
    this.status = 'active',
    this.createdAt,
    this.updatedAt,
  });

  factory WaterSectionPin.fromJson(Map<String, dynamic> json) {
    return WaterSectionPin(
      id: json['id'] ?? 0,
      sectionId: json['section_id'] ?? 0,
      postId: json['post_id'] ?? 0,
      pinnedBy: json['pinned_by'] ?? 0,
      weight: json['weight'] ?? 0,
      reason: json['reason'] ?? '',
      pinnedUntil: DateTime.tryParse(json['pinned_until'] ?? ''),
      status: json['status'] ?? 'active',
      createdAt: DateTime.tryParse(json['created_at'] ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at'] ?? ''),
    );
  }
}

/// 版块内禁言记录
class WaterSectionMute {
  final int id;
  final int sectionId;
  final int userId;
  final WaterModeratorUser? user;
  final int mutedBy;
  final String reason;
  final DateTime? until;
  final String status;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const WaterSectionMute({
    this.id = 0,
    this.sectionId = 0,
    required this.userId,
    this.user,
    this.mutedBy = 0,
    this.reason = '',
    this.until,
    this.status = 'active',
    this.createdAt,
    this.updatedAt,
  });

  factory WaterSectionMute.fromJson(Map<String, dynamic> json) {
    return WaterSectionMute(
      id: json['id'] ?? 0,
      sectionId: json['section_id'] ?? 0,
      userId: json['user_id'] ?? 0,
      user: json['User'] != null
          ? WaterModeratorUser.fromJson(json['User'])
          : null,
      mutedBy: json['muted_by'] ?? 0,
      reason: json['reason'] ?? '',
      until: DateTime.tryParse(json['until'] ?? ''),
      status: json['status'] ?? 'active',
      createdAt: DateTime.tryParse(json['created_at'] ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at'] ?? ''),
    );
  }

  String get displayName => user?.displayName ?? '用户 #$userId';

  bool get isExpired => until != null && until!.isBefore(DateTime.now());
}

/// 操作日志
class WaterModerationLog {
  final int id;
  final int sectionId;
  final int operatorId;
  final String targetType;
  final int targetId;
  final int? targetUserId;
  final String action;
  final String reason;
  final String snapshot;
  final DateTime? createdAt;

  const WaterModerationLog({
    this.id = 0,
    this.sectionId = 0,
    this.operatorId = 0,
    this.targetType = '',
    this.targetId = 0,
    this.targetUserId,
    this.action = '',
    this.reason = '',
    this.snapshot = '',
    this.createdAt,
  });

  factory WaterModerationLog.fromJson(Map<String, dynamic> json) {
    return WaterModerationLog(
      id: json['id'] ?? 0,
      sectionId: json['section_id'] ?? 0,
      operatorId: json['operator_id'] ?? 0,
      targetType: json['target_type'] ?? '',
      targetId: json['target_id'] ?? 0,
      targetUserId: json['target_user_id'] != null
          ? (json['target_user_id'] as num?)?.toInt()
          : null,
      action: json['action'] ?? '',
      reason: json['reason'] ?? '',
      snapshot: json['snapshot'] ?? '',
      createdAt: DateTime.tryParse(json['created_at'] ?? ''),
    );
  }

  String get actionLabel {
    switch (action) {
      case 'pin_post':
        return '置顶帖子';
      case 'unpin_post':
        return '取消置顶';
      case 'delete_post':
        return '删除帖子';
      case 'mute_user':
        return '禁言用户';
      case 'unmute_user':
        return '解除禁言';
      default:
        return action;
    }
  }
}

/// 分页日志
class WaterModerationLogPage {
  final List<WaterModerationLog> logs;
  final int page;
  final int pageSize;
  final int total;

  const WaterModerationLogPage({
    this.logs = const [],
    this.page = 1,
    this.pageSize = 20,
    this.total = 0,
  });

  factory WaterModerationLogPage.fromJson(Map<String, dynamic> json) {
    final list = (json['logs'] as List<dynamic>?) ?? [];
    return WaterModerationLogPage(
      logs: list
          .map((e) => WaterModerationLog.fromJson(e as Map<String, dynamic>))
          .toList(),
      page: json['page'] ?? 1,
      pageSize: json['page_size'] ?? 20,
      total: json['total'] ?? 0,
    );
  }
}
