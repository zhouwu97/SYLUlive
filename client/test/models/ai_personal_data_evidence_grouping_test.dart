import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/ai_personal_data_evidence.dart';

void main() {
  test('personal evidence is grouped by dataset and keeps the newest item', () {
    final older = AiPersonalDataEvidence(
      source: 'server_snapshot',
      dataset: 'grades',
      fetchedAt: DateTime(2026, 8, 21),
    );
    final newer = AiPersonalDataEvidence(
      source: 'remote_edu_fetch',
      dataset: 'grades',
      fetchedAt: DateTime(2026, 8, 23),
    );
    final credit = AiPersonalDataEvidence(
      source: 'server_snapshot',
      dataset: 'credit_requirements',
      fetchedAt: DateTime(2026, 8, 21),
    );

    final grouped = groupAiPersonalDataEvidence([older, newer, credit]);

    expect(grouped, hasLength(2));
    expect(
        grouped.map((item) => item.dataset),
        containsAll(<String>[
          'grades',
          'credit_requirements',
        ]));
    expect(grouped.singleWhere((item) => item.dataset == 'grades').source,
        'remote_edu_fetch');
  });
}
