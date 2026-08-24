import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
import 'package:shenliyuan/models/ai_quota.dart';
import 'package:shenliyuan/widgets/campus/campus_ai_entry_card.dart';

void main() {
  testWidgets('校园页只显示紧凑的校园 Agent 主入口', (tester) async {
    const capabilities = AiCapabilities(
      enabled: true,
      accessAllowed: true,
      internalTestOnly: false,
      chatEnabled: true,
      phase: 'p2',
      features: AiFeatures(
        policyRag: true,
        scheduleWindows: true,
        hy3CompetitionCompare: true,
        hy3AcademicAnalysis: true,
        hy3WeekPlan: true,
      ),
      quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
      maxMessageChars: 200,
    );
    var opened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampusAiEntryCard(
            capabilities: capabilities,
            isDark: false,
            onTap: () => opened = true,
          ),
        ),
      ),
    );

    expect(find.text('校园 Agent'), findsOneWidget);
    expect(find.text('帮你查信息、看安排、做计划'), findsOneWidget);
    expect(find.text('剩余 2 次'), findsOneWidget);
    expect(find.text('赛事对比'), findsNothing);
    expect(find.text('学业分析'), findsNothing);
    expect(find.text('本周计划'), findsNothing);

    await tester.tap(find.text('校园 Agent'));
    expect(opened, isTrue);
  });

  testWidgets('校园 AI 主入口展示不限次数', (tester) async {
    const capabilities = AiCapabilities(
      enabled: true,
      accessAllowed: true,
      internalTestOnly: false,
      chatEnabled: true,
      phase: 'p2',
      features: AiFeatures(policyRag: true, scheduleWindows: false),
      quota: AiQuota(
        limit: 3,
        remaining: 3,
        windowSeconds: 3600,
        unlimited: true,
      ),
      maxMessageChars: 20,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampusAiEntryCard(
            capabilities: capabilities,
            isDark: false,
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.text('不限次数'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
