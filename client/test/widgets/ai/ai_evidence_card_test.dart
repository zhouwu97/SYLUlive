import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/features/ai_runtime/skills/personal_skill.dart';
import 'package:shenliyuan/features/campus_data/storage/personal_snapshot_models.dart';
import 'package:shenliyuan/widgets/ai/ai_evidence_card.dart';

void main() {
  testWidgets('证据卡默认收起，展开后显示来源和数据时间', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiEvidenceCard(
            evidence: <SkillEvidence>[
              SkillEvidence(
                source: '本地加密 Vault',
                scope: 'GPA 计算课程范围',
                dataType: PersonalDataType.academic,
                fetchedAt: DateTime(2026, 7, 20, 8),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('数据与计算证据'), findsOneWidget);
    expect(find.text('GPA 计算课程范围'), findsNothing);
    await tester.tap(find.text('数据与计算证据'));
    await tester.pumpAndSettle();
    expect(find.text('GPA 计算课程范围'), findsOneWidget);
    expect(find.textContaining('本地加密 Vault'), findsOneWidget);
    expect(find.textContaining('2026-07-20 08:00'), findsOneWidget);
  });
}
