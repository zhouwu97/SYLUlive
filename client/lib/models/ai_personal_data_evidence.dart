class AiPersonalDataEvidence {
  const AiPersonalDataEvidence({
    required this.source,
    this.dataset = '',
    this.title = '',
    this.fetchedAt,
    this.expiresAt,
    this.isStale = false,
    this.analysisInput = const {},
  });

  final String source;
  final String dataset;
  final String title;
  final DateTime? fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;
  final Map<String, dynamic> analysisInput;

  factory AiPersonalDataEvidence.fromJson(Map<String, dynamic> json) {
    return AiPersonalDataEvidence(
      source: json['source']?.toString() ?? '',
      dataset: json['dataset']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      fetchedAt: _parseTime(json['fetched_at']),
      expiresAt: _parseTime(json['expires_at']),
      isStale: json['is_stale'] == true,
      analysisInput: json['analysis_input'] is Map
          ? Map<String, dynamic>.from(json['analysis_input'] as Map)
          : const {},
    );
  }

  String get sourceLabel => switch (source) {
        'server_snapshot' => '服务端教务快照',
        'device_encrypted_cache' => '手机本地加密缓存',
        'remote_edu_fetch' => '实时教务拉取',
        'user_uploaded_snapshot' => '用户上传快照',
        'hy3_mcp' => '学业数据来源',
        _ => '个人数据来源',
      };

  String get datasetLabel => switch (dataset) {
        'grades' => '成绩',
        'schedule' => '课表',
        'academic_situation' => '学业情况',
        'credit_requirements' => '学分要求',
        'credit_summary' => '学分摘要',
        'erke' => '二课',
        'academic_analysis' => '学业分析',
        _ => title,
      };

  String get stableKey =>
      '$source|$dataset|$title|${fetchedAt?.toUtc().toIso8601String() ?? ''}';

  List<AiAcademicCourseEvidence> get academicCourses {
    final raw = analysisInput['courses'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((item) => AiAcademicCourseEvidence.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList(growable: false);
  }

  String get academicCreditSummary {
    if (analysisInput.isEmpty) return '';
    final earned = _numberText(analysisInput['earned_credits']);
    final required = _numberText(analysisInput['required_credits']);
    final erkeEarned = _numberText(analysisInput['erke_earned']);
    final erkeRequired = _numberText(analysisInput['erke_required']);
    return '学分 $earned / $required · 二课 $erkeEarned / $erkeRequired';
  }

  static DateTime? _parseTime(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }
}

class AiAcademicCourseEvidence {
  const AiAcademicCourseEvidence({
    required this.name,
    this.grade = '',
    this.credits = '',
    this.isRequired = false,
    this.passed,
  });

  final String name;
  final String grade;
  final String credits;
  final bool isRequired;
  final bool? passed;

  factory AiAcademicCourseEvidence.fromJson(Map<String, dynamic> json) {
    return AiAcademicCourseEvidence(
      name: json['course_name']?.toString() ?? '',
      grade: _numberText(json['grade']),
      credits: _numberText(json['credits']),
      isRequired: json['is_required'] == true,
      passed: json['passed'] is bool ? json['passed'] as bool : null,
    );
  }

  String get detail {
    final values = <String>[
      if (grade.isNotEmpty) '成绩 $grade',
      if (credits.isNotEmpty) '$credits 学分',
      isRequired ? '必修' : '选修',
      if (passed != null) passed! ? '已通过' : '未通过',
    ];
    return values.join(' · ');
  }
}

String _numberText(Object? value) {
  if (value is num) {
    return value.toDouble() == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
  }
  return value?.toString() ?? '';
}
