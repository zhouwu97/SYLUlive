import 'package:flutter_test/flutter_test.dart';
import 'package:shenliyuan/models/ai_agent_activity.dart';
import 'package:shenliyuan/models/ai_agent_activity_reducer.dart';
import 'package:shenliyuan/models/ai_run_event.dart';

void main() {
  test('activity reducer 保留真实设备阶段且不生成固定四步', () {
    final activities = AiAgentActivityReducer.reduce([
      const AiRunEvent(
        runId: 'run-1',
        seq: 1,
        type: AiRunEventType.agentActivity,
        activityCode: 'checking_freshness',
        dataset: 'grades',
        status: 'running',
      ),
      const AiRunEvent(
        runId: 'run-1',
        seq: 2,
        type: AiRunEventType.agentActivity,
        activityCode: 'refresh_started',
        dataset: 'grades',
        status: 'running',
      ),
      const AiRunEvent(
        runId: 'run-1',
        seq: 3,
        type: AiRunEventType.agentActivity,
        activityCode: 'refresh_completed',
        dataset: 'grades',
        success: true,
      ),
    ]);

    expect(activities.map((item) => item.title), [
      '检查成绩更新时间',
      '正在获取最新成绩…',
      '已获取最新成绩',
    ]);
    expect(activities[1].status, AiAgentActivityStatus.running);
    expect(activities.map((item) => item.title), isNot(contains('检查服务端快照')));
  });

  test('失败 activity 明确显示失败而不是已完成', () {
    final activities = AiAgentActivityReducer.reduce([
      const AiRunEvent(
        runId: 'run-1',
        seq: 4,
        type: AiRunEventType.agentActivity,
        activityCode: 'refresh_failed',
        dataset: 'grades',
        status: 'failed',
        success: false,
      ),
    ]);
    expect(activities.single.status, AiAgentActivityStatus.failed);
    expect(activities.single.title, '没能获取最新成绩');
  });
}
