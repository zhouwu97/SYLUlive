/// 管理员接口中的用户摘要。
///
/// 与普通公开用户资料分开建模，避免管理员页面误用公开接口或静默吞掉管理字段。
class AdminUserSummary {
  final int id;
  final String studentId;
  final String nickname;
  final String avatar;
  final String role;
  final int creditScore;
  final int reportCount;
  final bool eduBound;

  const AdminUserSummary({
    required this.id,
    required this.studentId,
    required this.nickname,
    required this.avatar,
    required this.role,
    required this.creditScore,
    required this.reportCount,
    required this.eduBound,
  });

  factory AdminUserSummary.fromJson(Map<String, dynamic> json) {
    return AdminUserSummary(
      id: (json['id'] as num?)?.toInt() ?? 0,
      studentId: json['student_id']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
      avatar: json['avatar']?.toString() ?? '',
      role: json['role']?.toString() ?? 'user',
      creditScore: (json['credit_score'] as num?)?.toInt() ?? 100,
      reportCount: (json['report_count'] as num?)?.toInt() ?? 0,
      eduBound: json['edu_bound'] == true,
    );
  }

  bool get isAdmin => role == 'admin' || role == 'super_admin';
  bool get isSuperAdmin => role == 'super_admin';
  String get publicIdLabel => '用户 ID：$id';
  String get accountLabel =>
      studentId.isEmpty ? '学号/账号：未填写' : '学号/账号：$studentId';
}
