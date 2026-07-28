import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
import 'package:shenliyuan/models/ai_quota.dart';
import 'package:shenliyuan/widgets/campus/campus_ai_entry_card.dart';

void main() {
  testWidgets('校园 AI 卡片按服务端能力显示三个业务入口', (tester) async {
    const capabilities = AiCapabilities(
      enabled: true,
      accessAllowed: true,
      internalTestOnly: true,
      chatEnabled: false,
      phase: 'p0',
      features: AiFeatures(
        policyRag: false,
        scheduleWindows: false,
        hy3CompetitionCompare: true,
        hy3AcademicAnalysis: true,
        hy3WeekPlan: true,
      ),
      quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
      maxMessageChars: 200,
    );
    var opened = false;
    String? selectedAction;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampusAiEntryCard(
            capabilities: capabilities,
            isDark: false,
            onTap: () => opened = true,
            onCompetitionCompareTap: () => selectedAction = 'competition',
            onAcademicAnalysisTap: () => selectedAction = 'academic',
            onWeekPlanTap: () => selectedAction = 'week',
          ),
        ),
      ),
    );

    expect(find.text('沈理 AI'), findsOneWidget);
    expect(find.text('校园政策与课表助手'), findsOneWidget);
    expect(find.text('每小时 3 次 · 每次最多 200 字'), findsOneWidget);
    expect(find.text('剩余 2 次'), findsOneWidget);
    expect(find.text('赛事对比'), findsOneWidget);
    expect(find.text('学业分析'), findsOneWidget);
    expect(find.text('本周计划'), findsOneWidget);

    await tester.tap(find.text('赛事对比'));
    expect(selectedAction, 'competition');
    await tester.tap(find.text('学业分析'));
    expect(selectedAction, 'academic');
    await tester.tap(find.text('本周计划'));
    expect(selectedAction, 'week');
    await tester.tap(find.text('沈理 AI'));
    expect(opened, isTrue);
  });

  testWidgets('校园 AI 卡片展示不限次数', (tester) async {
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

    expect(find.text('使用次数不限 · 每次最多 20 字'), findsOneWidget);
    expect(find.text('不限次数'), findsOneWidget);
    expect(find.text('赛事对比'), findsNothing);
    expect(find.text('学业分析'), findsNothing);
    expect(find.text('本周计划'), findsNothing);
  });

  testWidgets('窄屏下只显示服务端实际注册的单项能力', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const capabilities = AiCapabilities(
      enabled: true,
      accessAllowed: true,
      internalTestOnly: false,
      chatEnabled: true,
      phase: 'p2',
      features: AiFeatures(
        policyRag: true,
        scheduleWindows: false,
        hy3AcademicAnalysis: true,
      ),
      quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
      maxMessageChars: 200,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampusAiEntryCard(
            capabilities: capabilities,
            isDark: false,
            onTap: () {},
            onCompetitionCompareTap: () {},
            onAcademicAnalysisTap: () {},
            onWeekPlanTap: () {},
          ),
        ),
      ),
    );

    expect(find.text('赛事对比'), findsNothing);
    expect(find.text('学业分析'), findsOneWidget);
    expect(find.text('本周计划'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
