import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/widgets/competition/competition_student_event_card.dart';
import 'package:shenliyuan/models/competition.dart';

void main() {
  testWidgets('CompetitionStudentEventCard basic render',
      (WidgetTester tester) async {
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
          showRecommendations: true,
        ),
      ),
    ));

    expect(find.text('Test Competition'), findsOneWidget);
    expect(find.text('人工 A'), findsOneWidget);
    expect(find.text('校认 S'), findsOneWidget);
  });

  testWidgets('内测目录模式不展示推荐等级、理由和个性化适配', (WidgetTester tester) async {
    final event = CompetitionEvent(
      id: 2,
      title: 'Beta Competition',
      summary: '公开赛事摘要',
      recommendationLevel: 'S',
      recommendationReason: '强烈推荐理由',
      fitReasons: const ['专业匹配'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompetitionStudentEventCard(
            event: event,
            onTap: () {},
            onAddPlan: () {},
            onJoinedTap: () {},
            showRecommendations: false,
          ),
        ),
      ),
    );

    expect(find.text('公开赛事摘要'), findsWidgets);
    expect(find.text('人工 S'), findsNothing);
    expect(find.text('强烈推荐理由'), findsNothing);
    expect(find.text('专业匹配'), findsNothing);
    expect(find.text('加入计划'), findsOneWidget);
  });
}
