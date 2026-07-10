import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../lib/widgets/competition/competition_student_event_card.dart';
import '../../../lib/models/competition.dart';

void main() {
  testWidgets('CompetitionStudentEventCard basic render', (WidgetTester tester) async {
    final event = CompetitionEvent(
      id: 1,
      title: 'Test Competition',
      summary: 'Summary',
      competitionLevel: 'A',
      schoolRecognitionStatus: 'recognized',
      schoolRecognitionGrade: 'S',
      recommendationLevel: 'A',
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompetitionStudentEventCard(
          event: event,
          onTap: () {},
          onAddPlan: () {},
          onJoinedTap: () {},
        ),
      ),
    ));

    expect(find.text('Test Competition'), findsOneWidget);
    expect(find.text('人工 A'), findsOneWidget);
    expect(find.text('校认 S'), findsOneWidget);
  });
}
