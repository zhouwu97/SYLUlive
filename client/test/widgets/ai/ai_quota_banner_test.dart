import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_quota.dart';
import 'package:shenliyuan/widgets/ai/ai_quota_banner.dart';

void main() {
  testWidgets('不限次数配额横幅显示明确状态', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiQuotaBanner(
            quota: AiQuota(
              limit: 3,
              remaining: 0,
              windowSeconds: 3600,
              unlimited: true,
            ),
            maxCharacters: 120,
          ),
        ),
      ),
    );

    expect(find.text('使用次数不限 · 每次最多 120 字'), findsOneWidget);
  });
}
