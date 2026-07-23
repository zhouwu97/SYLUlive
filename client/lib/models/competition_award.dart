class CompetitionAward {
  final int id;
  final int? competitionEventId;
  final String competitionTitle;
  final String trackName;
  final int competitionYear;
  final String awardName;
  final String awardLevel;
  final String competitionStage;
  final String role;
  final List<String> skillTags;
  final String contributionSummary;
  final List<int> evidenceFileIds;
  final String verificationStatus;
  final String verificationNote;
  final String visibility;

  const CompetitionAward({
    required this.id,
    this.competitionEventId,
    required this.competitionTitle,
    this.trackName = '',
    required this.competitionYear,
    required this.awardName,
    this.awardLevel = '',
    required this.competitionStage,
    required this.role,
    this.skillTags = const [],
    this.contributionSummary = '',
    this.evidenceFileIds = const [],
    this.verificationStatus = 'self_reported',
    this.verificationNote = '',
    this.visibility = 'private',
  });

  factory CompetitionAward.fromJson(Map<String, dynamic> json) {
    return CompetitionAward(
      id: (json['id'] as num?)?.toInt() ?? 0,
      competitionEventId: (json['competition_event_id'] as num?)?.toInt(),
      competitionTitle: '${json['competition_title'] ?? ''}',
      trackName: '${json['track_name'] ?? ''}',
      competitionYear: (json['competition_year'] as num?)?.toInt() ?? 0,
      awardName: '${json['award_name'] ?? ''}',
      awardLevel: '${json['award_level'] ?? ''}',
      competitionStage: '${json['competition_stage'] ?? ''}',
      role: '${json['role'] ?? ''}',
      skillTags: _strings(json['skill_tags']),
      contributionSummary: '${json['contribution_summary'] ?? ''}',
      evidenceFileIds: ((json['evidence_file_ids'] as List?) ?? const [])
          .map((value) => (value as num).toInt())
          .toList(),
      verificationStatus: '${json['verification_status'] ?? 'self_reported'}',
      verificationNote: '${json['verification_note'] ?? ''}',
      visibility: '${json['visibility'] ?? 'private'}',
    );
  }

  Map<String, dynamic> toPayload() => {
        'competition_event_id': competitionEventId,
        'competition_title': competitionTitle.trim(),
        'track_name': trackName.trim(),
        'competition_year': competitionYear,
        'award_name': awardName.trim(),
        'award_level': awardLevel.trim(),
        'competition_stage': competitionStage,
        'role': role,
        'skill_tags': skillTags,
        'contribution_summary': contributionSummary.trim(),
        'evidence_file_ids': evidenceFileIds,
        'visibility': visibility,
      };
}

List<String> _strings(dynamic value) => ((value as List?) ?? const [])
    .map((item) => '$item'.trim())
    .where((item) => item.isNotEmpty)
    .toList();

const competitionAwardStatusLabels = <String, String>{
  'self_reported': '本人填写',
  'pending': '材料待核验',
  'verified': '平台已核验',
  'rejected': '核验未通过',
};

const competitionAwardVisibilityLabels = <String, String>{
  'private': '仅自己',
  'profile': '个人主页',
  'team_matching': '组队匹配',
};

const competitionAwardStageLabels = <String, String>{
  'school': '校级',
  'provincial': '省级',
  'regional': '赛区级',
  'national': '国家级',
  'international': '国际级',
  'other': '其他',
};

const competitionAwardRoleLabels = <String, String>{
  'developer': '开发',
  'modeler': '建模',
  'hardware': '硬件',
  'designer': '设计',
  'writer': '文案',
  'presenter': '答辩',
  'organizer': '组织',
  'leader': '负责人',
  'member': '成员',
  'other': '其他',
};
