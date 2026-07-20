import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/poll.dart';

void main() {
  test('完整投票结果正确解析', () {
    final meta = PollMeta.fromJson({
      'id': 7,
      'post_id': 9,
      'category': 'study',
      'selection_mode': 'multiple',
      'max_choices': 2,
      'results_visibility': 'always',
      'allow_change': true,
      'status': 'active',
      'effective_status': 'active',
      'ends_at': '2026-07-20T12:00:00Z',
      'remaining_seconds': 3600,
      'participant_count': 10,
      'choice_count': 15,
      'has_voted': true,
      'results_visible': true,
      'can_vote': true,
      'can_change': true,
      'is_owner': false,
      'options': [
        {
          'id': 1,
          'text': '选项一',
          'sort_order': 0,
          'vote_count': 6,
          'ratio': 0.6,
          'is_chosen': true,
        }
      ],
    });

    expect(meta.choiceCount, 15);
    expect(meta.isMultiple, isTrue);
    expect(meta.options.single.voteCount, 6);
    expect(meta.options.single.ratio, 0.6);
    expect(meta.chosenOptionIds, [1]);
  });

  test('脱敏结果不会把缺失票数解析为零', () {
    final meta = PollMeta.fromJson({
      'id': 7,
      'post_id': 9,
      'ends_at': '2026-07-20T12:00:00Z',
      'participant_count': 10,
      'results_visible': false,
      'options': [
        {'id': 1, 'text': '隐藏选项', 'sort_order': 0, 'is_chosen': false}
      ],
    });

    expect(meta.choiceCount, isNull);
    expect(meta.options.single.voteCount, isNull);
    expect(meta.options.single.ratio, isNull);
    expect(meta.toJson().containsKey('choice_count'), isFalse);
    expect(meta.options.single.toJson().containsKey('vote_count'), isFalse);
  });
}
