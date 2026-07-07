// 当前用户在某个水帖版块内的等级与今日奖励状态。
class WaterSectionMyLevel {
  final int sectionId;
  final String sectionSlug;
  final String sectionTitle;
  final int level;
  final String title;
  final int exp;
  final int currentLevelMinExp;
  final int nextLevelExp;
  final int progressExp;
  final int requiredExp;
  final int postCount;
  final int replyCount;
  final bool todayPostAwarded;
  final bool todayReplyAwarded;
  final int postDailyExp;
  final int replyDailyExp;

  const WaterSectionMyLevel({
    required this.sectionId,
    required this.sectionSlug,
    required this.sectionTitle,
    required this.level,
    required this.title,
    required this.exp,
    required this.currentLevelMinExp,
    required this.nextLevelExp,
    required this.progressExp,
    required this.requiredExp,
    required this.postCount,
    required this.replyCount,
    required this.todayPostAwarded,
    required this.todayReplyAwarded,
    required this.postDailyExp,
    required this.replyDailyExp,
  });

  factory WaterSectionMyLevel.fromJson(Map<String, dynamic> json) {
    return WaterSectionMyLevel(
      sectionId: (json['section_id'] as num?)?.toInt() ?? 0,
      sectionSlug: json['section_slug'] ?? '',
      sectionTitle: json['section_title'] ?? '',
      level: (json['level'] as num?)?.toInt() ?? 1,
      title: json['title'] ?? '',
      exp: (json['exp'] as num?)?.toInt() ?? 0,
      currentLevelMinExp: (json['current_level_min_exp'] as num?)?.toInt() ?? 0,
      nextLevelExp: (json['next_level_exp'] as num?)?.toInt() ?? 0,
      progressExp: (json['progress_exp'] as num?)?.toInt() ?? 0,
      requiredExp: (json['required_exp'] as num?)?.toInt() ?? 0,
      postCount: (json['post_count'] as num?)?.toInt() ?? 0,
      replyCount: (json['reply_count'] as num?)?.toInt() ?? 0,
      todayPostAwarded: json['today_post_awarded'] == true,
      todayReplyAwarded: json['today_reply_awarded'] == true,
      postDailyExp: (json['post_daily_exp'] as num?)?.toInt() ?? 10,
      replyDailyExp: (json['reply_daily_exp'] as num?)?.toInt() ?? 3,
    );
  }

  bool get isMaxLevel => nextLevelExp <= 0 || requiredExp <= 0;

  double get progressRatio {
    if (isMaxLevel) return 1;
    return (progressExp / requiredExp).clamp(0.0, 1.0);
  }
}
