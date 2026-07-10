// WaterSectionLevelTitle 版块等级称号（每个版块 Lv.1-Lv.8 自定义）
class WaterSectionLevelTitle {
  final int level;
  final String title;
  final bool custom; // false 表示当前使用默认称号
  final int position; // 后端用法：自定义记录的 id；默认称号则为 0

  const WaterSectionLevelTitle({
    required this.level,
    required this.title,
    this.custom = false,
    this.position = 0,
  });

  factory WaterSectionLevelTitle.fromJson(Map<String, dynamic> json) {
    return WaterSectionLevelTitle(
      level: json['level'] ?? 1,
      title: json['title'] ?? '',
      custom: json['custom'] == true,
      position: json['position'] ?? 0,
    );
  }

  Map<String, dynamic> toInputMap() {
    return {'level': level, 'title': title};
  }
}
