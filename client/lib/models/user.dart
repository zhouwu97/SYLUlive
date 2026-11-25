// 用户模型
class User {
  final int id;
  final String studentId;
  final String loginAccount;
  String nickname;
  String gender;
  String avatar;
  String background;
  final String backgroundPreviewUrl;
  final int creditScore;
  final String role;
  final int adminExp;
  final int exp;
  final int credits;
  final int aiBalanceCents;
  final bool isCheckedInToday;
  final int reportCount;
  final DateTime createdAt;
  final bool legalConsentsActive;
  final bool legalConsentsRequired;
  final bool pushEnabled;
  final bool isAiBot;
  final int? botOwnerId;
  final String botOwnerNickname;

  // 账号身份与找回能力，仅在本人响应中由服务端返回。
  final bool studentVerified;
  final bool academicConfigured;
  final String emailMasked;
  final bool emailBound;
  final List<String> loginMethods;
  final bool canResetViaEmail;
  final bool canResetViaEdu;

  // 教务系统绑定信息
  final String eduStudentId;
  final bool eduBound;
  final bool eduAuthorized;
  final String eduSessionState;
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
    this.loginAccount = '',
    required this.nickname,
    this.gender = '',
    this.avatar = '',
    this.background = '',
    this.backgroundPreviewUrl = '',
    this.creditScore = 100,
    this.role = 'user',
    this.adminExp = 0,
    this.exp = 0,
    this.credits = 0,
    this.aiBalanceCents = 0,
    this.isCheckedInToday = false,
    this.reportCount = 0,
    required this.createdAt,
    this.legalConsentsActive = true,
    this.legalConsentsRequired = false,
    this.pushEnabled = false,
    this.isAiBot = false,
    this.botOwnerId,
    this.botOwnerNickname = '',
    this.studentVerified = false,
    this.academicConfigured = false,
    this.emailMasked = '',
    this.emailBound = false,
    this.loginMethods = const [],
    this.canResetViaEmail = false,
    this.canResetViaEdu = false,
    this.eduStudentId = '',
    this.eduBound = false,
    this.eduAuthorized = false,
    this.eduSessionState = 'unbound',
    this.eduGrade = '',
    this.eduCollege = '',
    this.eduMajor = '',
    this.followersCount = 0,
    this.followingCount = 0,
    this.totalLikesReceived = 0,
    this.isFollowing = false,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    final bot = json['ai_bot'] is Map ? json['ai_bot'] as Map : null;
    final ownerId = bot?['owner_id'];
    final ownerNickname = bot?['owner_nickname'];
    return User(
      id: json['id'] ?? 0,
      studentId: json['student_id'] ?? '',
      // 机器人身份由系统标签展示，昵称和正文里的服务端前缀不再重复显示。
      nickname: bot != null
          ? (json['nickname'] ?? '').toString().replaceFirst('[AI] ', '')
          : json['nickname'] ?? '',
      gender: json['gender'] ?? '',
      avatar: json['avatar'] ?? '',
      background: json['background'] ?? '',
      backgroundPreviewUrl: json['background_preview_url']?.toString() ?? '',
      creditScore: json['credit_score'] ?? 100,
      role: json['role'] ?? 'user',
      adminExp: json['admin_exp'] ?? 0,
      exp: json['exp'] ?? 0,
      credits: json['credits'] ?? 0,
      aiBalanceCents: json['ai_balance_cents'] ?? 0,
      isCheckedInToday: json['is_checked_in_today'] ?? false,
      reportCount: json['report_count'] ?? 0,
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
      legalConsentsActive: json['legal_consents_active'] == true,
      legalConsentsRequired: json['legal_consents_required'] == true ||
          !json.containsKey('legal_consents_active'),
      pushEnabled: json['push_enabled'] == true,
      isAiBot: bot != null,
      botOwnerId: ownerId is num &&
              ownerId.isFinite &&
              ownerId > 0 &&
              ownerId == ownerId.toInt()
          ? ownerId.toInt()
          : null,
      botOwnerNickname: ownerNickname is String ? ownerNickname.trim() : '',
      academicConfigured: json['academic_configured'] == true,
      studentVerified: json['student_verified'] == true,
      emailMasked: json['email_masked']?.toString() ?? '',
      emailBound: json['email_bound'] == true,
      loginAccount: json['login_account']?.toString() ?? '',
      loginMethods: (json['login_methods'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      canResetViaEmail: json['can_reset_via_email'] == true,
      canResetViaEdu: json['can_reset_via_edu'] == true,
      eduStudentId: json['edu_student_id'] ?? '',
      eduBound: json['edu_bound'] ?? false,
      eduAuthorized: json['edu_authorized'] == true ||
          (!json.containsKey('edu_authorized') && json['edu_bound'] == true),
      eduSessionState: json['edu_session_state']?.toString() ??
          ((json['edu_bound'] == true) ? 'active' : 'unbound'),
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
      'background_preview_url': backgroundPreviewUrl,
      'credit_score': creditScore,
      'role': role,
      'admin_exp': adminExp,
      'exp': exp,
      'credits': credits,
      'ai_balance_cents': aiBalanceCents,
      'is_checked_in_today': isCheckedInToday,
      'report_count': reportCount,
      'created_at': createdAt.toIso8601String(),
      'legal_consents_active': legalConsentsActive,
      'legal_consents_required': legalConsentsRequired,
      'push_enabled': pushEnabled,
      if (isAiBot)
        'ai_bot': {
          if (botOwnerId != null) 'owner_id': botOwnerId,
          'owner_nickname': botOwnerNickname,
        },
      'student_verified': studentVerified,
      'academic_configured': academicConfigured,
      'email_masked': emailMasked,
      'email_bound': emailBound,
      'login_account': loginAccount,
      'login_methods': loginMethods,
      'can_reset_via_email': canResetViaEmail,
      'can_reset_via_edu': canResetViaEdu,
      'edu_student_id': eduStudentId,
      'edu_bound': eduBound,
      'edu_authorized': eduAuthorized,
      'edu_session_state': eduSessionState,
      'edu_grade': eduGrade,
      'edu_college': eduCollege,
      'edu_major': eduMajor,
      'followers_count': followersCount,
      'following_count': followingCount,
      'total_likes_received': totalLikesReceived,
      'is_following': isFollowing,
    };
  }

  static String aiBotDisplayContent(String content, User? author) =>
      author?.isAiBot == true ? content.replaceFirst('[AI机器人] ', '') : content;

  bool get isAdmin => role == 'admin' || role == 'super_admin';
  bool get isSuperAdmin => role == 'super_admin';
  String get publicIdLabel => 'ID $id';
  String get aiBotLabel => botOwnerNickname.trim().isEmpty
      ? '独立 AI 机器人'
      : '${botOwnerNickname.trim()} 的 AI';

  /// 标签上的归属前缀：「纯合子创建的」；创建者未知时为空，只显示 AI 等级。
  String get aiBotOwnerPrefix => botOwnerNickname.trim().isNotEmpty
      ? '${botOwnerNickname.trim()}创建的'
      : botOwnerId != null
          ? '用户 #$botOwnerId 创建的'
          : '';
  String get aiBotCreatorLabel => botOwnerNickname.trim().isNotEmpty
      ? '由${botOwnerNickname.trim()}创建'
      : botOwnerId != null
          ? '由用户 #$botOwnerId 创建'
          : '创建者未公开';

  /// 用户等级阈值：Lv.1 0 / Lv.2 50 / Lv.3 150 / Lv.4 500 / Lv.5 1000 /
  /// Lv.6 2500 / Lv.7 5000 / Lv.8 8000。
  static const userLevelThresholds = [0, 50, 150, 500, 1000, 2500, 5000, 8000];

  /// AI 机器人只靠每日首帖/首评和人类获赞积累经验，阈值单独一套：
  /// Lv.1 0 / Lv.2 30 / Lv.3 100 / Lv.4 250 / Lv.5 600 / Lv.6 1200 / Lv.7 2500 / Lv.8 5000。
  static const aiLevelThresholds = [0, 30, 100, 250, 600, 1200, 2500, 5000];

  List<int> get _levelThresholds =>
      isAiBot ? aiLevelThresholds : userLevelThresholds;

  /// 根据经验值计算等级；AI 机器人使用 [aiLevelThresholds]。
  int get level =>
      (_levelThresholds.lastIndexWhere((threshold) => exp >= threshold) + 1)
          .clamp(1, 8);

  /// 升级到下一级所需的累计经验，满级为 0。
  int get expToNextLevel => level >= 8 ? 0 : _levelThresholds[level];

  /// 当前等级进度（0.0 - 1.0）
  double get levelProgress {
    if (level >= 8) return 1.0;
    final currentMin = _levelThresholds[level - 1];
    final needed = expToNextLevel - currentMin;
    if (needed <= 0) return 1.0;
    return ((exp - currentMin) / needed).clamp(0.0, 1.0);
  }

  /// 等级标签文字
  String get levelLabel => isAiBot ? 'AI Lv.$level' : 'Lv.$level';

  /// AI 等级主色，依次为天蓝、蓝青、青绿、雾靛、琥珀、珊瑚、樱粉、黑白。
  static const aiLevelColorValues = [
    0xFF3B82F6,
    0xFF0EA5E9,
    0xFF14B8A6,
    0xFF5B67E0,
    0xFFF59E0B,
    0xFFF26B4A,
    0xFFF43F5E,
    0xFF1F2329,
  ];

  /// 等级颜色
  int get levelColorValue {
    if (isAiBot) return aiLevelColorValues[level - 1];
    switch (level) {
      case 8:
        return 0xFFFF0000; // 烈焰红 - 终极神话
      case 7:
        return 0xFFD32F2F; // 炽红 - 巅峰的前奏
      case 6:
        return 0xFFFFA000; // 琥珀橙 - 荣耀光芒
      case 5:
        return 0xFF8E24AA; // 紫晶紫 - 尊贵神秘
      case 4:
        return 0xFF4682B4; // 深海蓝 / 钢蓝
      case 3:
        return 0xFF2E7D32; // 森林绿
      case 2:
        return 0xFF00897B; // 墨绿 - 初露锋芒
      case 1:
      default:
        return 0xFF616161; // 深灰 - 初始的沉淀
    }
  }
}
