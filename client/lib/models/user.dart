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
  final int exp;
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
    this.exp = 0,
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
      exp: json['exp'] ?? 0,
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
      'exp': exp,
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

  /// 根据经验值计算用户等级
  /// Level 1: 0-9 exp
  /// Level 2: 10-99 exp
  /// Level 3: 100-249 exp
  /// Level 4: 250-999 exp
  /// Level 5: 1000-2499 exp
  /// Level 6: 2500+ exp
  int get level {
    if (exp >= 2500) return 6;
    if (exp >= 1000) return 5;
    if (exp >= 250) return 4;
    if (exp >= 100) return 3;
    if (exp >= 10) return 2;
    return 1;
  }

  /// 升级到下一级所需经验
  int get expToNextLevel {
    switch (level) {
      case 1: return 10;
      case 2: return 100;
      case 3: return 250;
      case 4: return 1000;
      case 5: return 2500;
      default: return 0; // 已满级
    }
  }

  /// 当前等级进度（0.0 - 1.0）
  double get levelProgress {
    if (level >= 6) return 1.0;
    final currentMin = level == 1 ? 0 : [0, 10, 100, 250, 1000][level - 1];
    final needed = expToNextLevel - currentMin;
    if (needed <= 0) return 1.0;
    return ((exp - currentMin) / needed).clamp(0.0, 1.0);
  }

  /// 等级标签文字
  String get levelLabel => 'Lv.$level';

  /// 等级颜色
  int get levelColorValue {
    switch (level) {
      case 6: return 0xFFD4AF37; // 金色
      case 5: return 0xFFE040FB; // 紫色
      case 4: return 0xFF448AFF; // 蓝色
      case 3: return 0xFF00C853; // 绿色
      case 2: return 0xFFFF9800; // 橙色
      default: return 0xFF9E9E9E; // 灰色
    }
  }
}