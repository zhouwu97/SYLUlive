import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shenliyuan/models/competition.dart';
import 'package:shenliyuan/widgets/competition/competition_student_event_card.dart';

void main() {
  test('CompetitionEvent parses structured audience and fit metadata', () {
    final event = CompetitionEvent.fromJson({
      'id': 1,
      'title': '测试比赛',
      'eligible_entry_years': ['2023'],
      'eligible_colleges': ['信息科学与工程学院'],
      'eligible_majors': ['计算机科学与技术'],
      'fit_level': 'major',
      'fit_reasons': ['符合2023级', '专业匹配：计算机科学与技术'],
    });
    expect(event.eligibleEntryYears, ['2023']);
    expect(event.eligibleMajors, ['计算机科学与技术']);
    expect(event.fitLevel, 'major');
    expect(event.fitReasons, hasLength(2));
  });

  testWidgets('joined card shows state and one candidate reason',
      (tester) async {
    final event = CompetitionEvent(
      id: 1,
      title: '测试比赛',
      fitReasons: const ['符合2023级', '专业匹配：计算机科学与技术'],
      coreReason: '参赛资格和专业方向符合',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompetitionStudentEventCard(
            event: event,
            joined: true,
            onTap: () {},
            onAddPlan: () {},
            onJoinedTap: () {},
          ),
        ),
      ),
    );
    expect(find.text('已加入'), findsOneWidget);
    expect(find.text('参赛资格和专业方向符合'), findsOneWidget);
    expect(find.textContaining('符合2023级'), findsNothing);
  });
}
