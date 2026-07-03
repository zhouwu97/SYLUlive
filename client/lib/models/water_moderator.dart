/// 当前用户对某个版块的局部权限摘要
class WaterSectionPermission {
  final bool isGlobalAdmin;
  final bool isModerator;
  final String role;
  final bool canEditSection;
  final bool canManageTags;
  final bool canPinPost;
  final bool canDeletePost;
  final bool canMuteUser;
  final bool canManageModerators;

  const WaterSectionPermission({
    this.isGlobalAdmin = false,
    this.isModerator = false,
    this.role = '',
    this.canEditSection = false,
    this.canManageTags = false,
    this.canPinPost = false,
    this.canDeletePost = false,
    this.canMuteUser = false,
    this.canManageModerators = false,
  });

  factory WaterSectionPermission.empty() => const WaterSectionPermission();

  factory WaterSectionPermission.fromJson(Map<String, dynamic> json) {
    return WaterSectionPermission(
      isGlobalAdmin: json['is_global_admin'] == true,
      isModerator: json['is_moderator'] == true,
      role: json['role'] ?? '',
      canEditSection: json['can_edit_section'] == true,
      canManageTags: json['can_manage_tags'] == true,
      canPinPost: json['can_pin_post'] == true,
      canDeletePost: json['can_delete_post'] == true,
      canMuteUser: json['can_mute_user'] == true,
      canManageModerators: json['can_manage_moderators'] == true,
    );
  }

  /// admin/super_admin 或拥有版主任免权的用户可以看到任免版主入口
  bool get canManageModeratorsEntry => canManageModerators;
}

/// 版主用户摘要（仅公开字段）
class WaterModeratorUser {
  final int id;
  final String nickname;
  final String avatarUrl;

  const WaterModeratorUser({
    required this.id,
    this.nickname = '',
    this.avatarUrl = '',
  });

  factory WaterModeratorUser.fromJson(Map<String, dynamic> json) {
    return WaterModeratorUser(
      id: json['id'] ?? 0,
      nickname: json['nickname'] ?? '',
      avatarUrl: json['avatar'] ?? '',
    );
  }

  String get displayName => nickname.isNotEmpty ? nickname : '用户 #$id';
}

/// 版块版主记录
class WaterSectionModerator {
  final int id;
  final int sectionId;
  final String sectionSlug;
  final int userId;
  final WaterModeratorUser? user;
  final String role;
  final bool canEditSection;
  final bool canManageTags;
  final bool canPinPost;
  final bool canDeletePost;
  final bool canMuteUser;
  final String status;
  final int assignedBy;
  final String assignReason;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const WaterSectionModerator({
    required this.id,
    this.sectionId = 0,
    this.sectionSlug = '',
    required this.userId,
    this.user,
    this.role = 'moderator',
    this.canEditSection = false,
    this.canManageTags = false,
    this.canPinPost = false,
    this.canDeletePost = false,
    this.canMuteUser = false,
    this.status = 'active',
    this.assignedBy = 0,
    this.assignReason = '',
    this.createdAt,
    this.updatedAt,
  });

  factory WaterSectionModerator.fromJson(Map<String, dynamic> json) {
    return WaterSectionModerator(
      id: json['id'] ?? 0,
      sectionId: json['section_id'] ?? 0,
      sectionSlug: json['section_slug'] ?? '',
      userId: json['user_id'] ?? 0,
      user: json['user'] != null
          ? WaterModeratorUser.fromJson(json['user'])
          : null,
      role: json['role'] ?? 'moderator',
      canEditSection: json['can_edit_section'] == true,
      canManageTags: json['can_manage_tags'] == true,
      canPinPost: json['can_pin_post'] == true,
      canDeletePost: json['can_delete_post'] == true,
      canMuteUser: json['can_mute_user'] == true,
      status: json['status'] ?? 'active',
      assignedBy: json['assigned_by'] ?? 0,
      assignReason: json['assign_reason'] ?? '',
      createdAt: DateTime.tryParse(json['created_at'] ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at'] ?? ''),
    );
  }

  String get displayName => user?.displayName ?? '用户 #$userId';

  String get roleLabel => role == 'owner' ? '负责人' : '版主';

  /// 权限摘要列表（仅已启用的）
  List<String> get enabledPermissions {
    final list = <String>[];
    if (canEditSection) list.add('编辑展示');
    if (canManageTags) list.add('管理标签');
    if (canPinPost) list.add('置顶');
    if (canDeletePost) list.add('删帖');
    if (canMuteUser) list.add('禁言');
    return list;
  }
}
