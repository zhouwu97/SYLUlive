import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_quota.dart';
import 'package:shenliyuan/widgets/ai/ai_quota_banner.dart';

void main() {
  testWidgets('无限配额账号显示不限次数', (tester) async {
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

    expect(find.textContaining('测试账号不限提问次数'), findsOneWidget);
    expect(find.textContaining('额度已用完'), findsNothing);
  });
}
