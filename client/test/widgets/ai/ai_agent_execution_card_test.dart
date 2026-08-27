import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_agent_activity.dart';
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
    expect(find.text('正在获取最新成绩…'), findsNWidgets(2));
    expect(find.text('检查成绩更新时间'), findsNothing);
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

    expect(find.text('正在处理当前问题…'), findsOneWidget);
    expect(find.text('检查服务端快照'), findsNothing);
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
    expect(find.text('正在读取课表数据…'), findsNWidgets(2));

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
    expect(find.text('正在读取课表数据…'), findsNothing);

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
    expect(find.text('Agent 处理未完成'), findsNWidgets(2));
  });

  testWidgets('刷新失败时提供重新获取和使用已有数据', (tester) async {
    var retryCount = 0;
    var staleCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAgentExecutionCard(
            activities: <AiAgentActivity>[
              AiAgentActivity(
                id: 'failed-refresh',
                runId: 'run-1',
                code: 'refresh_failed',
                dataset: 'grades',
                status: AiAgentActivityStatus.failed,
                title: '没能获取最新成绩',
                detail: '手机没有返回已验证的新数据',
                timestamp: DateTime(2026, 8, 23),
              ),
            ],
            onRetryRefresh: () => retryCount++,
            onUseExistingData: () => staleCount++,
          ),
        ),
      ),
    );

    expect(find.text('重新获取'), findsOneWidget);
    expect(find.text('使用已有数据'), findsOneWidget);
    await tester.tap(find.text('重新获取'));
    await tester.tap(find.text('使用已有数据'));
    expect(retryCount, 1);
    expect(staleCount, 1);
  });

  testWidgets('完成后显示摘要，并可查看未合并的完整审计过程', (tester) async {
    final summary = AiAgentActivity(
      id: 'summary',
      runId: 'run-audit',
      code: 'tool.completed',
      dataset: 'academic',
      status: AiAgentActivityStatus.success,
      title: '已读取学业数据',
      detail: '',
      timestamp: DateTime.utc(2026, 8, 25),
    );
    const rawEvents = [
      AiRunEvent(
        runId: 'run-audit',
        seq: 1,
        type: AiRunEventType.agentActivity,
        activityCode: 'device_job_completed',
      ),
      AiRunEvent(
        runId: 'run-audit',
        seq: 2,
        type: AiRunEventType.agentActivity,
        activityCode: 'device_resume_claimed',
      ),
      AiRunEvent(
        runId: 'run-audit',
        seq: 3,
        type: AiRunEventType.agentActivity,
        activityCode: 'device_result_consumed',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAgentExecutionCard(
            activities: [summary],
            rawEvents: rawEvents,
            running: true,
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAgentExecutionCard(
            activities: [summary],
            rawEvents: rawEvents,
            completed: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已完成分析'), findsOneWidget);
    expect(find.text('查看完整过程'), findsOneWidget);
    expect(find.text('设备任务已完成'), findsNothing);

    await tester.tap(find.text('查看完整过程'));
    await tester.pumpAndSettle();
    expect(find.text('查看技术详情'), findsOneWidget);
    await tester.tap(find.text('查看技术详情'));
    await tester.pumpAndSettle();
    expect(find.text('设备任务已完成'), findsOneWidget);
    expect(find.text('已接收设备结果'), findsOneWidget);
    expect(find.text('已读取设备更新结果'), findsOneWidget);
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
