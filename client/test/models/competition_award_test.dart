import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition_award.dart';

void main() {
  test('解析竞赛经历并使用安全默认值', () {
    final award = CompetitionAward.fromJson(<String, dynamic>{
      'id': 9,
      'competition_title': '中国大学生计算机设计大赛',
      'competition_year': 2026,
      'award_name': '二等奖',
      'competition_stage': 'provincial',
      'role': 'developer',
      'skill_tags': ['Flutter', ' Dart ', ''],
      'evidence_file_ids': [31, 32],
    });

    expect(award.competitionEventId, isNull);
    expect(award.skillTags, ['Flutter', 'Dart']);
    expect(award.evidenceFileIds, [31, 32]);
    expect(award.verificationStatus, 'self_reported');
    expect(award.visibility, 'private');
  });

  test('保存载荷不包含平台核验字段', () {
    const award = CompetitionAward(
      id: 9,
      competitionEventId: 7,
      competitionTitle: ' 程序设计竞赛 ',
      competitionYear: 2026,
      awardName: ' 一等奖 ',
      competitionStage: 'national',
      role: 'developer',
      verificationStatus: 'verified',
      verificationNote: '不应回传',
      visibility: 'profile',
    );

    final payload = award.toPayload();
    expect(payload['competition_title'], '程序设计竞赛');
    expect(payload['award_name'], '一等奖');
    expect(payload['visibility'], 'profile');
    expect(payload.containsKey('verification_status'), isFalse);
    expect(payload.containsKey('verification_note'), isFalse);
    expect(payload.containsKey('verified_by'), isFalse);
    expect(payload.containsKey('verified_at'), isFalse);
  });
}
