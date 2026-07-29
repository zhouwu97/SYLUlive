import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/campus_data/erke/erke_models.dart';
import 'package:shenliyuan/features/personal_data_sync/erke_snapshot_upload.dart';

void main() {
  test('二课上传载荷仅保留摘要字段和最近二十条活动', () {
    final payload = ErkeSnapshotUploadPayload.fromSnapshot(
      ErkeSnapshot(
        fetchedAt: DateTime.utc(2026, 7, 25, 1, 20),
        graduation: const ErkeGraduationSummary(
          requiredTotal: 60,
          earnedTotal: 42.5,
          rawTotalGap: 17.5,
          categoryGap: 4,
          graduationGap: 17.5,
          unmetCount: 1,
          officialConclusion: '未达标',
          categories: <ErkeRequirementCategory>[
            ErkeRequirementCategory(
              code: 'C',
              name: '创新创业',
              required: 8,
              earned: 4,
              meetsNumerically: false,
            ),
          ],
        ),
        yearly: const ErkeYearlySummary(
          year: '2025-2026',
          availableYears: <String>['2025-2026'],
          requiredTotal: 10,
          yearEarnedTotal: 6,
          cumulativeTotal: 42.5,
          rawYearGap: 4,
          categoryGap: 2,
          minimumGap: 4,
          officialConclusion: '本学年未达标',
          categories: <ErkeYearlyCategory>[],
        ),
        activities: List<ErkeActivity>.generate(
          24,
          (index) => ErkeActivity(
            item: '不应上传的活动名称 $index',
            score: '1.5',
            date: '2026-07-25',
            category: '创新创业',
          ),
        ),
      ),
    ).toJson();

    expect(payload['schema_version'], 2);
    expect(payload['fetched_at'], '2026-07-25T01:20:00.000Z');
    expect(payload['graduation'], <String, dynamic>{
      'earned_total': 42.5,
      'required_total': 60.0,
      'graduation_gap': 17.5,
      'unmet_categories': <Map<String, dynamic>>[
        <String, dynamic>{'name': '创新创业', 'gap': 4.0},
      ],
      'official_conclusion': '未达标',
    });
    expect(payload['yearly'], containsPair('yearly_gap', 4.0));

    final activities = payload['recent_activities'] as List<dynamic>;
    expect(activities, hasLength(20));
    expect(activities.first, <String, dynamic>{
      'category': '创新创业',
      'score': 1.5,
      'date': '2026-07-25',
    });
    expect(activities.first.containsKey('item'), isFalse);
  });
}
