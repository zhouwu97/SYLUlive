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

  test('读取设备结果和继续分析阶段保持 running', () {
    final activities = AiAgentActivityReducer.reduce([
      const AiRunEvent(
        runId: 'run-1',
        seq: 4,
        type: AiRunEventType.agentActivity,
        activityCode: 'reading_result',
        dataset: 'grades',
      ),
      const AiRunEvent(
        runId: 'run-1',
        seq: 5,
        type: AiRunEventType.agentActivity,
        activityCode: 'provider_started',
      ),
    ]);

    expect(activities.map((item) => item.status), [
      AiAgentActivityStatus.running,
      AiAgentActivityStatus.running,
    ]);
    expect(activities.last.title, '正在继续分析…');
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

  test('原始审计层保留同一任务的每个真实事件，摘要层才负责合并', () {
    final events = [
      AiRunEvent.fromJson({
        'run_id': 'run-audit',
        'seq': 1,
        'type': 'ai.device.job.completed',
        'payload': {
          'call_id': 'call-1',
          'job_id': 'job-1',
          'tool_name': 'device.academic.ensure_fresh_bundle',
          'datasets': ['grades', 'academic_situation', 'credit_requirements'],
          'status': 'completed',
        },
      }),
      AiRunEvent.fromJson({
        'run_id': 'run-audit',
        'seq': 2,
        'type': 'ai.device.resume.claimed',
        'payload': {
          'call_id': 'call-1',
          'job_id': 'job-1',
          'tool_name': 'device.academic.ensure_fresh_bundle',
          'datasets': ['grades', 'academic_situation', 'credit_requirements'],
        },
      }),
      AiRunEvent.fromJson({
        'run_id': 'run-audit',
        'seq': 3,
        'type': 'ai.device.result.consumed',
        'payload': {
          'call_id': 'call-1',
          'job_id': 'job-1',
          'tool_name': 'device.academic.ensure_fresh_bundle',
          'datasets': ['grades', 'academic_situation', 'credit_requirements'],
        },
      }),
    ];

    final raw = AiAgentActivityReducer.reduceRaw(events);
    final summary = AiAgentActivityReducer.reduce(events);

    expect(raw, hasLength(3));
    expect(raw.map((item) => item.title), [
      '设备任务已完成',
      '已接收设备结果',
      '已读取设备更新结果',
    ]);
    expect(summary, hasLength(1));
  });

  test('设备失败终态不会显示为完成，并保留教务会话错误码', () {
    final event = AiRunEvent.fromJson({
      'run_id': 'run-failed',
      'seq': 1,
      'type': 'ai.device.job.failed',
      'payload': {
        'call_id': 'call-1',
        'job_id': 'job-1',
        'tool_name': 'device.academic.ensure_fresh_bundle',
        'datasets': ['grades', 'academic_situation', 'credit_requirements'],
        'status': 'failed',
        'error_code': 'EDU_SESSION_EXPIRED',
      },
    });

    final activity = AiAgentActivityReducer.reduce([event]).single;
    expect(activity.status, AiAgentActivityStatus.failed);
    expect(activity.code, 'device_job_failed');
    expect(activity.title, '手机更新学业失败');
    expect(activity.errorCode, 'EDU_SESSION_EXPIRED');
    expect(activity.detail, '教务登录状态已失效，请重新验证教务');
  });

  test('模型配置错误会给出管理员可执行的恢复说明', () {
    const event = AiRunEvent(
      runId: 'run-model-unavailable',
      seq: 1,
      type: AiRunEventType.failed,
      errorCode: 'provider_model_unavailable',
      retryable: true,
    );

    final activity = AiAgentActivityReducer.reduce([event]).single;
    expect(activity.status, AiAgentActivityStatus.failed);
    expect(activity.detail, '当前回答模型暂不可用，管理员需要检查服务配置');
  });

  test('课表工具失败事件不会显示为已读取，并保留预算错误原因', () {
    const event = AiRunEvent(
      runId: 'run-budget',
      seq: 1,
      type: AiRunEventType.toolCompleted,
      dataset: 'schedule',
      toolName: 'schedule_get_availability',
      errorCode: 'agent_same_tool_budget_exhausted',
      success: false,
    );

    final activity = AiAgentActivityReducer.reduce([event]).single;
    expect(activity.status, AiAgentActivityStatus.failed);
    expect(activity.detail, '课表查询重复步骤过多，请重新提问');
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
