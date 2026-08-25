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

  test('同一个 call 和 job 的设备阶段折叠为一行，并优先使用显式数据集', () {
    final activities = AiAgentActivityReducer.reduce([
      const AiRunEvent(
        runId: 'run-1',
        seq: 1,
        type: AiRunEventType.agentActivity,
        activityCode: 'checking_freshness',
        dataset: 'credit_requirements',
        toolName: 'academic_get_risk_analysis',
        callId: 'call-1',
        jobId: 'job-1',
        status: 'running',
      ),
      const AiRunEvent(
        runId: 'run-1',
        seq: 2,
        type: AiRunEventType.agentActivity,
        activityCode: 'refresh_started',
        dataset: 'credit_requirements',
        toolName: 'academic_get_risk_analysis',
        callId: 'call-1',
        jobId: 'job-1',
        status: 'running',
      ),
      const AiRunEvent(
        runId: 'run-1',
        seq: 3,
        type: AiRunEventType.agentActivity,
        activityCode: 'refresh_completed',
        dataset: 'credit_requirements',
        toolName: 'academic_get_risk_analysis',
        callId: 'call-1',
        jobId: 'job-1',
        success: true,
      ),
    ]);

    expect(activities, hasLength(1));
    expect(activities.single.title, '已获取最新学分要求');
  });

  test('Agent Contract v5 活动事件映射为目标、重规划和待确认状态', () {
    final activities = AiAgentActivityReducer.reduce([
      AiRunEvent.fromJson({
        'run_id': 'run-5',
        'seq': 1,
        'type': 'goal.updated',
        'payload': {'objective': '选择竞赛'},
      }),
      AiRunEvent.fromJson({
        'run_id': 'run-5',
        'seq': 2,
        'type': 'plan.revised',
        'payload': {'text': '发现时间冲突，正在调整'},
      }),
      AiRunEvent.fromJson({
        'run_id': 'run-5',
        'seq': 3,
        'type': 'approval.required',
        'payload': {'text': '请确认安排'},
      }),
    ]);

    expect(activities.map((item) => item.code), [
      'goal.updated',
      'plan.revised',
      'approval.required',
    ]);
    expect(activities.last.status, AiAgentActivityStatus.pending);
    expect(activities.last.detail, '请确认安排');
  });
}
