// 用户模型
class User {
  final int id;
  final String studentId;
  String nickname;
  String gender;
  String avatar;
  String background;
  final int creditScore;
  final String role;
  final int adminExp;
  final int exp;
  final int credits;
  final int aiBalanceCents;
  final bool isCheckedInToday;
  final int reportCount;
  final DateTime createdAt;

  // 教务系统绑定信息
  final String eduStudentId;
  final bool eduBound;
  final String eduGrade;
  final String eduCollege;
  final String eduMajor;

  // 社交统计
  int followersCount;
  int followingCount;
  int totalLikesReceived;
  bool isFollowing;

  User({
    required this.id,
    required this.studentId,
    required this.nickname,
    this.gender = '',
    this.avatar = '',
    this.background = '',
    this.creditScore = 100,
    this.role = 'user',
    this.adminExp = 0,
    this.exp = 0,
    this.credits = 0,
    this.aiBalanceCents = 0,
    this.isCheckedInToday = false,
    this.reportCount = 0,
    required this.createdAt,
    this.eduStudentId = '',
    this.eduBound = false,
    this.eduGrade = '',
    this.eduCollege = '',
    this.eduMajor = '',
    this.followersCount = 0,
    this.followingCount = 0,
    this.totalLikesReceived = 0,
    this.isFollowing = false,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] ?? 0,
      studentId: json['student_id'] ?? '',
      nickname: json['nickname'] ?? '',
      gender: json['gender'] ?? '',
      avatar: json['avatar'] ?? '',
      background: json['background'] ?? '',
      creditScore: json['credit_score'] ?? 100,
      role: json['role'] ?? 'user',
      adminExp: json['admin_exp'] ?? 0,
      exp: json['exp'] ?? 0,
      credits: json['credits'] ?? 0,
      aiBalanceCents: json['ai_balance_cents'] ?? 0,
      isCheckedInToday: json['is_checked_in_today'] ?? false,
      reportCount: json['report_count'] ?? 0,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      eduStudentId: json['edu_student_id'] ?? '',
      eduBound: json['edu_bound'] ?? false,
      eduGrade: json['edu_grade'] ?? '',
      eduCollege: json['edu_college'] ?? '',
      eduMajor: json['edu_major'] ?? '',
      followersCount: json['followers_count'] ?? 0,
      followingCount: json['following_count'] ?? 0,
      totalLikesReceived: json['total_likes_received'] ?? 0,
      isFollowing: json['is_following'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'student_id': studentId,
      'nickname': nickname,
      'gender': gender,
      'avatar': avatar,
      'background': background,
      'credit_score': creditScore,
      'role': role,
      'admin_exp': adminExp,
      'exp': exp,
      'credits': credits,
      'ai_balance_cents': aiBalanceCents,
      'is_checked_in_today': isCheckedInToday,
      'report_count': reportCount,
      'created_at': createdAt.toIso8601String(),
      'edu_student_id': eduStudentId,
      'edu_bound': eduBound,
      'edu_grade': eduGrade,
      'edu_college': eduCollege,
      'edu_major': eduMajor,
      'followers_count': followersCount,
      'following_count': followingCount,
      'total_likes_received': totalLikesReceived,
      'is_following': isFollowing,
    };
  }

  bool get isAdmin => role == 'admin' || role == 'super_admin';
  bool get isSuperAdmin => role == 'super_admin';

  /// 根据经验值计算用户等级
  /// Level 1: 0-49 exp
  /// Level 2: 50-149 exp
  /// Level 3: 150-499 exp
  /// Level 4: 500-999 exp
  /// Level 5: 1000-2499 exp
  /// Level 6: 2500-4999 exp
  /// Level 7: 5000-7999 exp
  /// Level 8: 8000+ exp
  int get level {
    if (exp >= 8000) return 8;
    if (exp >= 5000) return 7;
    if (exp >= 2500) return 6;
    if (exp >= 1000) return 5;
    if (exp >= 500) return 4;
    if (exp >= 150) return 3;
    if (exp >= 50) return 2;
    return 1;
  }

  /// 升级到下一级所需经验
  int get expToNextLevel {
    switch (level) {
      case 1: return 50;
      case 2: return 150;
      case 3: return 500;
      case 4: return 1000;
      case 5: return 2500;
      case 6: return 5000;
      case 7: return 8000;
      default: return 0; // 已满级
    }
  }

  /// 当前等级进度（0.0 - 1.0）
  double get levelProgress {
    if (level >= 8) return 1.0;
    final currentMin = level == 1 ? 0 : [0, 50, 150, 500, 1000, 2500, 5000, 8000][level - 1];
    final needed = expToNextLevel - currentMin;
    if (needed <= 0) return 1.0;
    return ((exp - currentMin) / needed).clamp(0.0, 1.0);
  }

  /// 等级标签文字
  String get levelLabel => 'Lv.$level';

  /// 等级颜色
  int get levelColorValue {
    switch (level) {
      case 8: return 0xFFFF0000; // 烈焰红 - 终极神话
      case 7: return 0xFFD32F2F; // 炽红 - 巅峰的前奏
      case 6: return 0xFFFFA000; // 琥珀橙 - 荣耀光芒
      case 5: return 0xFF8E24AA; // 紫晶紫 - 尊贵神秘
      case 4: return 0xFF4682B4; // 深海蓝 / 钢蓝
      case 3: return 0xFF2E7D32; // 森林绿
      case 2: return 0xFF00897B; // 墨绿 - 初露锋芒
      case 1: 
      default: return 0xFF616161; // 深灰 - 初始的沉淀
    }
  }
}
