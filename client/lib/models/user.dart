// 用户模型
class User {
  final int id;
  final String studentId;
  final String nickname;
  final String avatar;
  final String background;
  final int creditScore;
  final String role;
  final int adminExp;
  final int reportCount;
  final DateTime createdAt;

  // 教务系统绑定信息
  final String eduStudentId;
  final bool eduBound;
  final String eduGrade;
  final String eduCollege;
  final String eduMajor;

  User({
    required this.id,
    required this.studentId,
    required this.nickname,
    this.avatar = '',
    this.background = '',
    this.creditScore = 100,
    this.role = 'user',
    this.adminExp = 0,
    this.reportCount = 0,
    required this.createdAt,
    this.eduStudentId = '',
    this.eduBound = false,
    this.eduGrade = '',
    this.eduCollege = '',
    this.eduMajor = '',
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] ?? 0,
      studentId: json['student_id'] ?? '',
      nickname: json['nickname'] ?? '',
      avatar: json['avatar'] ?? '',
      background: json['background'] ?? '',
      creditScore: json['credit_score'] ?? 100,
      role: json['role'] ?? 'user',
      adminExp: json['admin_exp'] ?? 0,
      reportCount: json['report_count'] ?? 0,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      eduStudentId: json['edu_student_id'] ?? '',
      eduBound: json['edu_bound'] ?? false,
      eduGrade: json['edu_grade'] ?? '',
      eduCollege: json['edu_college'] ?? '',
      eduMajor: json['edu_major'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'student_id': studentId,
      'nickname': nickname,
      'avatar': avatar,
      'background': background,
      'credit_score': creditScore,
      'role': role,
      'admin_exp': adminExp,
      'report_count': reportCount,
      'created_at': createdAt.toIso8601String(),
      'edu_student_id': eduStudentId,
      'edu_bound': eduBound,
      'edu_grade': eduGrade,
      'edu_college': eduCollege,
      'edu_major': eduMajor,
    };
  }

  bool get isAdmin => role == 'admin' || role == 'super_admin';
  bool get isSuperAdmin => role == 'super_admin';
}