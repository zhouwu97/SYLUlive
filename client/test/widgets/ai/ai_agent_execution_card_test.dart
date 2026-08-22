import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_run_event.dart';
import 'package:shenliyuan/widgets/ai/ai_agent_execution_card.dart';

void main() {
  testWidgets('设备执行卡展示 freshness 链路并支持 reduced motion', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(1.3),
          disableAnimations: true,
        ),
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                AiAgentExecutionCard(
                  event: const AiRunEvent(
                    type: AiRunEventType.eduFetching,
                    datasets: ['grades'],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
        find.byKey(const ValueKey('ai-agent-execution-card')), findsOneWidget);
    expect(find.text('正在检查需要的数据'), findsOneWidget);
    expect(find.textContaining('只在需要时唤醒设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
