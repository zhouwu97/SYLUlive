import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/competition_action_draft.dart';

void main() {
  test('竞赛计划草稿只恢复安全预览字段并支持状态更新', () {
    final draft = CompetitionPlanActionDraft.fromJson(<String, dynamic>{
      'id': 12,
      'action_type': 'add_competition_to_plan',
      'status': 'pending',
      'expires_at': '2026-07-23T12:00:00Z',
      'event': <String, dynamic>{
        'id': 7,
        'title': '人工智能竞赛',
        'personalized_score': 86,
        'fit_reasons': <String>['方向匹配'],
        'manual_rating': 4.5,
      },
      'evidence_file_ids': <int>[99],
      'verification_note': '不得进入预览',
    });

    expect(draft.id, 12);
    expect(draft.event.title, '人工智能竞赛');
    expect(draft.isPending, isTrue);
    expect(draft.toJson().containsKey('evidence_file_ids'), isFalse);
    expect(draft.toJson().containsKey('verification_note'), isFalse);
    expect(draft.copyWith(status: 'executed').status, 'executed');
  });
}
