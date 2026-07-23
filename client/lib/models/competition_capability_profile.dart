class CompetitionCapabilityCount {
  final String value;
  final int verifiedCount;
  final int selfReportedCount;

  const CompetitionCapabilityCount({
    required this.value,
    required this.verifiedCount,
    required this.selfReportedCount,
  });

  factory CompetitionCapabilityCount.fromJson(
    Map<String, dynamic> json, {
    required String valueKey,
  }) {
    return CompetitionCapabilityCount(
      value: json[valueKey]?.toString() ?? '',
      verifiedCount: (json['verified_count'] as num?)?.toInt() ?? 0,
      selfReportedCount: (json['self_reported_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class CompetitionCapabilityProfile {
  final bool preferenceConfigured;
  final List<String> goals;
  final int verifiedAwardCount;
  final int selfReportedAwardCount;
  final List<CompetitionCapabilityCount> skillSummary;
  final List<CompetitionCapabilityCount> roleSummary;
  final List<String> directionTags;
  final List<String> preferredRoles;
  final int weeklyHours;
  final bool acceptLongTermTraining;

  const CompetitionCapabilityProfile({
    required this.preferenceConfigured,
    required this.goals,
    required this.verifiedAwardCount,
    required this.selfReportedAwardCount,
    required this.skillSummary,
    required this.roleSummary,
    required this.directionTags,
    required this.preferredRoles,
    required this.weeklyHours,
    required this.acceptLongTermTraining,
  });

  factory CompetitionCapabilityProfile.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) => ((json[key] as List?) ?? const [])
        .map((value) => value.toString())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);

    List<CompetitionCapabilityCount> counts(String key, String valueKey) =>
        ((json[key] as List?) ?? const [])
            .map(
              (value) => CompetitionCapabilityCount.fromJson(
                Map<String, dynamic>.from(value as Map),
                valueKey: valueKey,
              ),
            )
            .where((value) => value.value.isNotEmpty)
            .toList(growable: false);

    return CompetitionCapabilityProfile(
      preferenceConfigured: json['preference_configured'] == true,
      goals: strings('goals'),
      verifiedAwardCount: (json['verified_award_count'] as num?)?.toInt() ?? 0,
      selfReportedAwardCount:
          (json['self_reported_award_count'] as num?)?.toInt() ?? 0,
      skillSummary: counts('skill_summary', 'skill'),
      roleSummary: counts('role_summary', 'role'),
      directionTags: strings('direction_tags'),
      preferredRoles: strings('preferred_roles'),
      weeklyHours: (json['weekly_hours'] as num?)?.toInt() ?? 0,
      acceptLongTermTraining: json['accept_long_term_training'] == true,
    );
  }
}

class CompetitionCapabilityAIAccess {
  final bool enabled;
  final DateTime? enabledAt;

  const CompetitionCapabilityAIAccess({
    required this.enabled,
    required this.enabledAt,
  });

  factory CompetitionCapabilityAIAccess.fromJson(Map<String, dynamic> json) {
    return CompetitionCapabilityAIAccess(
      enabled: json['enabled'] == true,
      enabledAt: DateTime.tryParse(json['enabled_at']?.toString() ?? ''),
    );
  }
}
