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
      competitionRating: 'A',
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
    expect(find.text('价值 A'), findsOneWidget);
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
      personalizedScore: 88,
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
    expect(find.text('价值 S'), findsNothing);
    expect(find.text('强烈推荐理由'), findsNothing);
    expect(find.text('专业匹配'), findsNothing);
    expect(find.text('偏好匹配 88'), findsNothing);
    expect(find.text('加入计划'), findsOneWidget);
  });

  testWidgets('适合我模式仅展示核心原因和最多两条风险', (WidgetTester tester) async {
    final event = CompetitionEvent(
      id: 3,
      title: 'Preference Competition',
      fitReasons: const ['方向匹配'],
      personalizedScore: 78,
      recommendationTier: 'recommended',
      coreReason: '专业与参赛资格符合目录要求',
      cautions: const ['报名时间待确认', '需要组队', '校赛名额有限'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompetitionStudentEventCard(
            event: event,
            onTap: () {},
            onAddPlan: () {},
            onJoinedTap: () {},
          ),
        ),
      ),
    );

    expect(find.textContaining('偏好匹配'), findsNothing);
    expect(find.text('方向匹配'), findsNothing);
    expect(find.text('专业与参赛资格符合目录要求'), findsOneWidget);
    expect(find.text('报名时间待确认 · 需要组队'), findsOneWidget);
    expect(find.textContaining('校赛名额有限'), findsNothing);
  });

  testWidgets('未配置偏好时不展示匹配分数', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompetitionStudentEventCard(
            event: CompetitionEvent(id: 4, title: 'Legacy Competition'),
            onTap: () {},
            onAddPlan: () {},
            onJoinedTap: () {},
          ),
        ),
      ),
    );

    expect(find.textContaining('偏好匹配'), findsNothing);
  });
}
