import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_quota.dart';
import 'package:shenliyuan/widgets/ai/ai_quota_banner.dart';

void main() {
  testWidgets('不限次数配额不占用正常内容空间', (tester) async {
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
            maxCharacters: 20,
          ),
        ),
      ),
    );

    expect(find.textContaining('使用次数不限'), findsNothing);
  });

  testWidgets('低配额才显示轻量提示', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiQuotaBanner(
            quota: AiQuota(
              limit: 10,
              remaining: 2,
              windowSeconds: 3600,
            ),
            maxCharacters: 20,
          ),
        ),
      ),
    );

    expect(find.textContaining('额度即将用完'), findsOneWidget);
  });
}
