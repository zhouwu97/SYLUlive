import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_capabilities.dart';
import 'package:shenliyuan/models/ai_quota.dart';
import 'package:shenliyuan/widgets/campus/campus_ai_entry_card.dart';

void main() {
  testWidgets('校园 AI 卡片展示配额与 120 字限制', (tester) async {
    const capabilities = AiCapabilities(
      enabled: true,
      accessAllowed: true,
      internalTestOnly: true,
      chatEnabled: false,
      phase: 'p0',
      features: AiFeatures(policyRag: false, scheduleWindows: false),
      quota: AiQuota(limit: 3, remaining: 2, windowSeconds: 3600),
      maxMessageChars: 120,
    );
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CampusAiEntryCard(
            capabilities: capabilities,
            isDark: false,
            onTap: () => tapped = true,
          ),
        ),
      ),
    );

    expect(find.text('沈理 AI'), findsOneWidget);
    expect(find.text('校园政策与课表助手'), findsOneWidget);
    expect(find.text('每小时 3 次 · 每次最多 120 字'), findsOneWidget);
    expect(find.text('剩余 2 次'), findsOneWidget);
    await tester.tap(find.byType(InkWell));
    expect(tapped, isTrue);
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
      maxMessageChars: 120,
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

    expect(find.text('使用次数不限 · 每次最多 120 字'), findsOneWidget);
    expect(find.text('不限次数'), findsOneWidget);
  });
}
