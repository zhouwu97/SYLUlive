import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition_dashboard_summary.dart';

void main() {
  test('解析竞赛档案轻量汇总', () {
    final summary = CompetitionDashboardSummary.fromJson({
      'preference_configured': true,
      'primary_goal': 'ability',
      'primary_direction': '算法',
      'weekly_hours': 7,
      'award_total': 3,
      'verified_award_count': 1,
      'self_reported_award_count': 1,
      'pending_award_count': 1,
      'rejected_award_count': 0,
      'capability_ready': true,
    });

    expect(summary.preferenceConfigured, isTrue);
    expect(summary.primaryDirection, '算法');
    expect(summary.awardTotal, 3);
    expect(summary.pendingAwardCount, 1);
    expect(summary.capabilityReady, isTrue);
  });
}
