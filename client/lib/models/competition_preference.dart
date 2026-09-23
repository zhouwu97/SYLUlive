class CompetitionPreference {
  final bool configured;
  final List<String> goals;
  final List<String> directionTags;
  final List<String> skillTags;
  final List<String> preferredRoles;
  final int weeklyHours;
  final bool acceptLongTermTraining;
  final String careerDirection;
  final String experienceLevel;
  final CompetitionProfile competitionProfile;
  /// 用户手动纠正的专业簇。留空表示按专业名自动推断。
  /// 这是长尾专业唯一的自救路径：推断不出来时由用户指定即可参与匹配。
  final List<String> majorClusterOverride;
  /// 服务端下发的专业簇词表（只读）。刻意不写死在客户端：
  /// 目录侧新增簇时，两边各抄一份必然漂移，写进去的错值还会被接口拒绝。
  final List<String> majorClusterOptions;

  const CompetitionPreference({
    this.configured = false,
    this.goals = const [],
    this.directionTags = const [],
    this.skillTags = const [],
    this.preferredRoles = const [],
    this.weeklyHours = 0,
    this.acceptLongTermTraining = false,
    this.careerDirection = '',
    this.experienceLevel = 'beginner',
    this.majorClusterOverride = const [],
    this.majorClusterOptions = const [],
    this.competitionProfile = const CompetitionProfile(),
  });

  factory CompetitionPreference.fromJson(Map<String, dynamic> json) {
    return CompetitionPreference(
      configured: json['configured'] == true,
      goals: _stringList(json['goals']),
      directionTags: _stringList(json['direction_tags']),
      skillTags: _stringList(json['skill_tags']),
      preferredRoles: _stringList(json['preferred_roles']),
      weeklyHours: (json['weekly_hours'] as num?)?.toInt() ?? 0,
      acceptLongTermTraining: json['accept_long_term_training'] == true,
      careerDirection: '${json['career_direction'] ?? ''}',
      experienceLevel: '${json['experience_level'] ?? 'beginner'}',
      majorClusterOverride: _stringList(json['major_cluster_override']),
      majorClusterOptions: _stringList(json['major_cluster_options']),
      competitionProfile: CompetitionProfile.fromJson(
        json['competition_profile'] is Map
            ? Map<String, dynamic>.from(json['competition_profile'] as Map)
            : const <String, dynamic>{},
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'goals': goals,
        'direction_tags': directionTags,
        'skill_tags': skillTags,
        'preferred_roles': preferredRoles,
        'weekly_hours': weeklyHours,
        'accept_long_term_training': acceptLongTermTraining,
        'career_direction': careerDirection.trim(),
        'experience_level': experienceLevel,
        // 显式传空数组表示清空纠正；不传则服务端保留原值。
        'major_cluster_override': majorClusterOverride,
        'competition_profile': competitionProfile.toJson(),
      };

  static List<String> _stringList(dynamic value) =>
      (value as List? ?? const []).map((item) => '$item').toList();
}

class CompetitionProfile {
  final String entryYear;
  final String college;
  final String major;
  final String provenance;
  final DateTime? updatedAt;

  const CompetitionProfile({
    this.entryYear = '',
    this.college = '',
    this.major = '',
    this.provenance = '',
    this.updatedAt,
  });

  factory CompetitionProfile.fromJson(Map<String, dynamic> json) =>
      CompetitionProfile(
        entryYear: '${json['entry_year'] ?? ''}',
        college: '${json['college'] ?? ''}',
        major: '${json['major'] ?? ''}',
        provenance: '${json['provenance'] ?? ''}',
        updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
      );

  Map<String, dynamic> toJson() => {
        'entry_year': entryYear.trim(),
        'college': college.trim(),
        'major': major.trim(),
      };
}

const competitionGoalLabels = <String, String>{
  'resume': '简历提升',
  'ability': '能力成长',
  'exploration': '探索体验',
  'postgraduate': '保研准备',
  'graduation_gap': '毕业补齐',
};

const competitionDirectionOptions = <String>[
  '程序设计',
  '数学建模',
  '电子设计',
  '机械制造',
  '创新创业',
  '商业分析',
  '外语',
  '艺术设计',
  '生命科学',
  '智能汽车',
  '机器人',
];

const competitionSkillOptions = <String>[
  'C++',
  'Python',
  '算法',
  '建模',
  '数据分析',
  '硬件',
  '嵌入式',
  '机械设计',
  '文案',
  '答辩',
  '设计',
  '项目管理',
];

const competitionRoleLabels = <String, String>{
  'developer': '开发',
  'modeler': '建模',
  'hardware': '硬件',
  'designer': '设计',
  'writer': '文案',
  'presenter': '答辩',
  'organizer': '组织',
  'any': '均可',
};

const competitionExperienceLabels = <String, String>{
  'beginner': '新手',
  'participated': '参加过',
  'awarded': '获得过奖项',
  'experienced': '经验丰富',
};

const competitionWeeklyHourLabels = <int, String>{
  0: '暂不确定',
  3: '1～3 小时',
  7: '4～7 小时',
  14: '8～14 小时',
  20: '15 小时以上',
};
