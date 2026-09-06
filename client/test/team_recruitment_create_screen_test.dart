import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shenliyuan/providers/auth_provider.dart';
import 'package:shenliyuan/providers/team_recruitment_provider.dart';
import 'package:shenliyuan/screens/team/team_recruitment_create_screen.dart';

import 'helpers/golden_test_app.dart';
import 'helpers/golden_viewport.dart';

void main() {
  Future<void> pumpCreateScreen(
    WidgetTester tester, {
    required Size viewport,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    await setGoldenViewport(tester, viewport);
    await tester.pumpWidget(
      GoldenTestApp(
        textScaler: textScaler,
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AuthProvider(Dio())),
            ChangeNotifierProvider(
                create: (_) => TeamRecruitmentProvider(Dio())),
          ],
          child: const TeamRecruitmentCreateScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('窄屏创建页的名额区与底部操作不会溢出', (tester) async {
    await pumpCreateScreen(tester, viewport: const Size(320, 800));

    expect(find.text('希望再招几名队友？'), findsOneWidget);
    expect(find.text('期望技能 / 招募方向'), findsOneWidget);
    expect(find.text('预览'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('大字号下的创建页保持可用且推荐方向可切换', (tester) async {
    await pumpCreateScreen(
      tester,
      viewport: GoldenViewports.phone360x800,
      textScaler: const TextScaler.linear(1.5),
    );

    final role = find.widgetWithText(FilterChip, '数学建模');
    expect(role, findsOneWidget);
    expect(tester.widget<FilterChip>(role).selected, isFalse);

    await tester.drag(find.byType(ListView), const Offset(0, -640));
    await tester.pump();
    await tester.tap(role);
    await tester.pump();

    expect(tester.widget<FilterChip>(role).selected, isTrue);
    expect(find.textContaining('💡'), findsNothing);
    expect(find.text('📋 结构化模板'), findsNothing);
    expect(find.text('🏆 学科竞赛'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
