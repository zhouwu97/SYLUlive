import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_run_event.dart';
import 'package:shenliyuan/widgets/ai/ai_agent_execution_card.dart';
import 'package:shenliyuan/widgets/ai/ai_agent_permission_card.dart';

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
    expect(find.text('正在更新成绩数据'), findsOneWidget);
    expect(find.textContaining('使用现有教务授权会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Run 刚建立且没有 event 时立即显示连接过程卡', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiAgentExecutionCard(event: null, running: true),
        ),
      ),
    );

    expect(find.text('正在连接校园 Agent'), findsOneWidget);
    expect(find.text('正在建立安全会话'), findsOneWidget);
    expect(find.text('检查服务端快照'), findsOneWidget);
  });

  testWidgets('正常完成后自动收起，失败时保留展开', (tester) async {
    const event = AiRunEvent(
      runId: 'run-1',
      type: AiRunEventType.toolExecuting,
      datasets: ['schedule'],
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiAgentExecutionCard(event: event, running: true),
        ),
      ),
    );
    expect(find.text('检查服务端快照'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiAgentExecutionCard(
            event: AiRunEvent(
              runId: 'run-1',
              type: AiRunEventType.completed,
              datasets: ['schedule'],
            ),
            completed: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('检查服务端快照'), findsNothing);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiAgentExecutionCard(
            event: AiRunEvent(
              runId: 'run-1',
              type: AiRunEventType.failed,
              datasets: ['schedule'],
            ),
          ),
        ),
      ),
    );
    expect(find.text('检查服务端快照'), findsOneWidget);
  });

  testWidgets('单次授权独立于 Process Card 且不出现长期授权文案', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AiAgentPermissionCard(
            event: AiRunEvent(
              type: AiRunEventType.consentRequired,
              datasets: ['grades'],
              consentReason: '成绩数据需要更新',
            ),
          ),
        ),
      ),
    );

    expect(
        find.byKey(const ValueKey('ai-agent-permission-card')), findsOneWidget);
    expect(find.text('暂不允许'), findsOneWidget);
    expect(find.text('允许本次'), findsOneWidget);
    expect(find.text('今后自动执行'), findsNothing);
  });
}
