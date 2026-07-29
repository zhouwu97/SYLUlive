class CompetitionDashboardSummary {
  final bool preferenceConfigured;
  final String primaryGoal;
  final String primaryDirection;
  final int weeklyHours;
  final int awardTotal;
  final int verifiedAwardCount;
  final int selfReportedAwardCount;
  final int pendingAwardCount;
  final int rejectedAwardCount;
  final bool capabilityReady;

  const CompetitionDashboardSummary({
    required this.preferenceConfigured,
    required this.primaryGoal,
    required this.primaryDirection,
    required this.weeklyHours,
    required this.awardTotal,
    required this.verifiedAwardCount,
    required this.selfReportedAwardCount,
    required this.pendingAwardCount,
    required this.rejectedAwardCount,
    required this.capabilityReady,
  });

  factory CompetitionDashboardSummary.fromJson(Map<String, dynamic> json) {
    int count(String key) => (json[key] as num?)?.toInt() ?? 0;
    return CompetitionDashboardSummary(
      preferenceConfigured: json['preference_configured'] == true,
      primaryGoal: '${json['primary_goal'] ?? ''}',
      primaryDirection: '${json['primary_direction'] ?? ''}',
      weeklyHours: count('weekly_hours'),
      awardTotal: count('award_total'),
      verifiedAwardCount: count('verified_award_count'),
      selfReportedAwardCount: count('self_reported_award_count'),
      pendingAwardCount: count('pending_award_count'),
      rejectedAwardCount: count('rejected_award_count'),
      capabilityReady: json['capability_ready'] == true,
    );
  }
}
