import 'ai_agent_activity.dart';
import 'ai_run_event.dart';

/// 把真实 SSE 事件折叠成用户能读懂的动作；固定流程模板不得在这里生成。
class AiAgentActivityReducer {
  const AiAgentActivityReducer._();

  static List<AiAgentActivity> reduce(
    Iterable<AiRunEvent> events, {
    bool completed = false,
  }) {
    final result = <AiAgentActivity>[];
    for (final event in events) {
      final activity = _fromEvent(event);
      if (activity == null) continue;
      result.add(activity);
    }
    if (completed && result.isNotEmpty && result.last.code != 'run.completed') {
      final last = result.last;
      result.add(AiAgentActivity(
        id: '${last.runId}:completed',
        runId: last.runId,
        code: 'run.completed',
        dataset: last.dataset,
        status: AiAgentActivityStatus.success,
        title: '已完成分析',
        detail: last.freshnessAfter == 'fresh' ? '已使用刚刚更新的数据' : '',
        timestamp: DateTime.now(),
        toolName: last.toolName,
        callId: last.callId,
        jobId: last.jobId,
        freshnessAfter: last.freshnessAfter,
        success: true,
      ));
    }
    return List.unmodifiable(result);
  }

  static AiAgentActivity? _fromEvent(AiRunEvent event) {
    final code = event.type == AiRunEventType.agentActivity
        ? event.activityCode
        : _eventCode(event.type);
    if (code.isEmpty) return null;
    final dataset = event.dataset.isNotEmpty
        ? event.dataset
        : (event.datasets.isNotEmpty ? event.datasets.first : '');
    final isFailure = event.type == AiRunEventType.failed ||
        event.activityCode == 'refresh_failed' ||
        event.status == 'failed';
    final status = isFailure
        ? AiAgentActivityStatus.failed
        : event.type == AiRunEventType.approvalRequired
            ? AiAgentActivityStatus.pending
            : event.type == AiRunEventType.agentActivity &&
                    (event.status == 'running' ||
                        event.activityCode == 'refresh_started')
                ? AiAgentActivityStatus.running
                : (event.type == AiRunEventType.toolExecuting ||
                        event.type == AiRunEventType.eduFetching ||
                        event.activityCode == 'checking_freshness')
                    ? AiAgentActivityStatus.running
                    : AiAgentActivityStatus.success;
    final title = _title(code, dataset, event);
    final detail = event.text.trim().isNotEmpty
        ? event.text.trim()
        : _detail(code, event, dataset);
    return AiAgentActivity(
      id: '${event.runId}:${event.seq}:$code:${event.jobId}',
      runId: event.runId,
      code: code,
      dataset: dataset,
      status: status,
      title: title,
      detail: detail,
      timestamp: event.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0),
      toolName: event.toolName,
      callId: event.callId,
      jobId: event.jobId,
      freshnessBefore: event.freshnessBefore,
      freshnessAfter: event.freshnessAfter,
      success: event.success || status == AiAgentActivityStatus.success,
    );
  }

  static String _eventCode(AiRunEventType type) => switch (type) {
        AiRunEventType.toolRequested => 'tool.requested',
        AiRunEventType.toolExecuting => 'tool.executing',
        AiRunEventType.deviceWaiting => 'device.waiting',
        AiRunEventType.deviceClaimed => 'request_received',
        AiRunEventType.consentRequired => 'consent.required',
        AiRunEventType.eduFetching => 'refresh_started',
        AiRunEventType.toolCompleted => 'tool.completed',
        AiRunEventType.goalUpdated => 'goal.updated',
        AiRunEventType.contextResolved => 'context.resolved',
        AiRunEventType.planRevised => 'plan.revised',
        AiRunEventType.approvalRequired => 'approval.required',
        AiRunEventType.actionCommitted => 'action.committed',
        AiRunEventType.actionFailed => 'action.failed',
        AiRunEventType.completed => 'run.completed',
        AiRunEventType.failed => 'run.failed',
        AiRunEventType.cancelled => 'run.cancelled',
        _ => '',
      };

  static String _title(String code, String dataset, AiRunEvent event) {
    final label = _datasetLabel(dataset, event.toolName);
    return switch (code) {
      'checking_freshness' => '检查$label更新时间',
      'device.waiting' => '已向你的手机请求最新$label',
      'request_received' => '手机已收到请求',
      'refresh_started' => '正在获取最新$label…',
      'refresh_completed' => '已获取最新$label',
      'refresh_failed' => '没能获取最新$label',
      'reading_result' => '正在读取已更新$label',
      'tool.requested' => _toolTitle(event.toolName, label),
      'tool.executing' => _toolTitle(event.toolName, label),
      'tool.completed' => '已读取$label数据',
      'goal.updated' => '已理解你的目标和限制',
      'context.resolved' => '已核对当前页面和授权上下文',
      'plan.revised' => '正在根据最新结果调整计划',
      'approval.required' => '安排已拟好，等待你的确认',
      'action.committed' => '安排已添加',
      'action.failed' => '安排未能添加',
      'consent.required' => '需要你的许可才能更新$label',
      'run.completed' => '已完成分析',
      'run.failed' => label == '成绩' ? '没能获取最新成绩' : 'Agent 处理未完成',
      'run.cancelled' => '本次处理已取消',
      _ => event.text.trim().isEmpty ? '正在处理$label' : event.text.trim(),
    };
  }

  static String _detail(String code, AiRunEvent event, String dataset) {
    if (code == 'tool.completed' && event.text.trim().isNotEmpty) {
      return event.text.trim();
    }
    if (event.freshnessAfter == 'fresh') {
      return '数据已验证为最新';
    }
    if (code == 'run.failed') {
      return '可以稍后重新获取，或选择使用已有数据';
    }
    return '';
  }

  static String _toolTitle(String toolName, String label) {
    if (toolName.contains('competition')) return '正在查找近期竞赛…';
    if (toolName.contains('canteen')) return '正在查看食堂评分…';
    return '正在读取$label数据…';
  }

  static String _datasetLabel(String dataset, String toolName) {
    if (dataset == 'grades' ||
        toolName.contains('grade') ||
        toolName.contains('academic')) {
      return '成绩';
    }
    if (dataset == 'schedule' || toolName.contains('schedule')) {
      return '课表';
    }
    if (dataset == 'erke' || toolName.contains('erke')) {
      return '二课';
    }
    return '校园数据';
  }
}
