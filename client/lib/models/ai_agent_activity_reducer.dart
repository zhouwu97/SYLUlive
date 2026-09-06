import 'ai_agent_activity.dart';
import 'ai_run_event.dart';

/// 把真实 SSE 事件折叠成用户能读懂的动作；固定流程模板不得在这里生成。
class AiAgentActivityReducer {
  const AiAgentActivityReducer._();

  /// 保留每一条服务端审计事件，供展开态展示完整过程。
  ///
  /// 这里不能按 call/job 合并；同一个设备任务的等待、完成、消费是三条
  /// 不同的事实，合并后用户无法核对真实执行顺序。
  static List<AiAgentActivity> reduceRaw(Iterable<AiRunEvent> events) {
    final result = <AiAgentActivity>[];
    for (final event in events) {
      final activity = _fromEvent(event);
      if (activity != null) result.add(activity);
    }
    return List.unmodifiable(result);
  }

  static List<AiAgentActivity> reduce(
    Iterable<AiRunEvent> events, {
    bool completed = false,
  }) {
    final result = <AiAgentActivity>[];
    final identityIndexes = <String, int>{};
    final callIndexes = <String, int>{};
    for (final event in events) {
      final activity = _fromEvent(event);
      if (activity == null) continue;
      final callKey = _callKey(activity);
      final identityKey = _identityKey(activity);
      int? index = identityKey == null ? null : identityIndexes[identityKey];
      if (index == null && activity.jobId.isNotEmpty && callKey != null) {
        final callIndex = callIndexes[callKey];
        if (callIndex != null && result[callIndex].jobId.isEmpty) {
          index = callIndex;
        }
      }
      if (index == null && activity.jobId.isEmpty && callKey != null) {
        index = callIndexes[callKey];
      }
      if (index == null) {
        index = result.length;
        result.add(activity);
      } else {
        result[index] = _merge(result[index], activity);
      }
      if (identityKey != null) identityIndexes[identityKey] = index;
      if (callKey != null) callIndexes[callKey] = index;
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
        errorCode: last.errorCode,
        success: true,
      ));
    }
    return List.unmodifiable(result);
  }

  static String? _callKey(AiAgentActivity activity) {
    if (activity.callId.isEmpty) return null;
    return '${activity.runId}:${activity.callId}';
  }

  static String? _identityKey(AiAgentActivity activity) {
    if (activity.callId.isEmpty && activity.jobId.isEmpty) return null;
    return '${activity.runId}:${activity.callId}:${activity.jobId}';
  }

  static AiAgentActivity _merge(
    AiAgentActivity previous,
    AiAgentActivity latest,
  ) {
    return AiAgentActivity(
      id: previous.id,
      runId: latest.runId,
      code: latest.code,
      dataset: latest.dataset.isEmpty ? previous.dataset : latest.dataset,
      status: latest.status,
      title: latest.title,
      detail: latest.detail,
      timestamp: latest.timestamp,
      toolName: latest.toolName.isEmpty ? previous.toolName : latest.toolName,
      callId: latest.callId.isEmpty ? previous.callId : latest.callId,
      jobId: latest.jobId.isEmpty ? previous.jobId : latest.jobId,
      freshnessBefore: latest.freshnessBefore.isEmpty
          ? previous.freshnessBefore
          : latest.freshnessBefore,
      freshnessAfter: latest.freshnessAfter.isEmpty
          ? previous.freshnessAfter
          : latest.freshnessAfter,
      errorCode:
          latest.errorCode.isEmpty ? previous.errorCode : latest.errorCode,
      success: latest.success,
    );
  }

  static AiAgentActivity? _fromEvent(AiRunEvent event) {
    final code = event.type == AiRunEventType.agentActivity
        ? event.activityCode
        : _eventCode(event.type);
    if (code.isEmpty) return null;
    final isAcademicBundle = event.datasets.length > 1 &&
        event.datasets.contains('grades') &&
        event.datasets.contains('academic_situation') &&
        event.datasets.contains('credit_requirements');
    final dataset = isAcademicBundle
        ? 'academic'
        : event.dataset.isNotEmpty
            ? event.dataset
            : (event.datasets.isNotEmpty ? event.datasets.first : '');
    final isFailure = event.type == AiRunEventType.failed ||
        (event.type == AiRunEventType.toolCompleted &&
            !event.success &&
            event.errorCode.trim().isNotEmpty) ||
        event.activityCode == 'refresh_failed' ||
        event.activityCode == 'provider_failed' ||
        event.activityCode == 'device_job_failed' ||
        event.activityCode == 'device_job_cancelled' ||
        event.activityCode == 'device_job_expired' ||
        event.status == 'failed';
    final status = isFailure
        ? AiAgentActivityStatus.failed
        : event.type == AiRunEventType.approvalRequired
            ? AiAgentActivityStatus.pending
            : event.type == AiRunEventType.deviceWaiting
                ? AiAgentActivityStatus.pending
                : event.type == AiRunEventType.agentActivity &&
                        (event.status == 'running' ||
                            event.activityCode == 'refresh_started' ||
                            event.activityCode == 'reading_result' ||
                            event.activityCode == 'provider_started')
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
      errorCode: event.errorCode,
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
      'device_job_completed' => _deviceJobTitle(dataset, event, legacy: true),
      'device_job_succeeded' => '手机已完成$label更新',
      'device_job_failed' => '手机更新$label失败',
      'device_job_cancelled' => '设备任务已取消',
      'device_job_expired' => '设备任务已超时',
      'device_resume_claimed' => '已接收设备结果',
      'device_result_consumed' => _consumedDeviceTitle(dataset, event),
      'tool_retry_waiting' => '正在等待下一项数据',
      'tool_retry_completed' => '已完成数据读取',
      'provider_started' => '正在继续分析…',
      'provider_completed' => '已生成分析结果',
      'provider_failed' => '分析未完成',
      'goal.updated' => '已理解你的目标和限制',
      'context.resolved' => '已核对当前页面和授权上下文',
      'plan.revised' => '正在根据最新结果调整计划',
      'approval.required' => '安排已拟好，等待你的确认',
      'action.committed' => '安排已添加',
      'action.failed' => '安排未能添加',
      'consent.required' => '需要你的许可才能更新$label',
      'run.completed' => '已完成分析',
      'run.failed' => _runFailureTitle(label, event),
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
      return _errorDetail(event.errorCode, dataset, event.toolName) ??
          '可以稍后重新获取，或选择使用已有数据';
    }
    final errorDetail = _errorDetail(event.errorCode, dataset, event.toolName);
    if (errorDetail != null) return errorDetail;
    return '';
  }

  static String _deviceJobTitle(
    String dataset,
    AiRunEvent event, {
    required bool legacy,
  }) {
    final status = event.status.trim().toLowerCase();
    if (status == 'failed') {
      return '手机更新${_datasetLabel(dataset, event.toolName)}失败';
    }
    if (status == 'cancelled') return '设备任务已取消';
    if (status == 'expired') return '设备任务已超时';
    return legacy
        ? '设备任务已完成'
        : '手机已完成${_datasetLabel(dataset, event.toolName)}更新';
  }

  static String _consumedDeviceTitle(String dataset, AiRunEvent event) {
    final status = event.status.trim().toLowerCase();
    if (status == 'failed') {
      return '已收到${_datasetLabel(dataset, event.toolName)}失败结果';
    }
    if (status == 'cancelled') return '已收到设备取消结果';
    if (status == 'expired') return '已收到设备超时结果';
    return '已读取设备更新结果';
  }

  static String _runFailureTitle(String label, AiRunEvent event) {
    if (_isEduSessionCode(event.errorCode)) return '教务登录状态已失效';
    return label == '成绩' ? '没能获取最新成绩' : 'Agent 处理未完成';
  }

  static String? _errorDetail(String code, String dataset, String toolName) {
    final label = _datasetLabel(dataset, toolName);
    switch (code.trim().toLowerCase()) {
      case 'edu_authorization_revoked':
      case 'edu_session_logged_out':
      case 'edu_session_expired':
      case 'edu_credential_unavailable':
        return '教务登录状态已失效，请重新验证教务';
      case 'credential_unavailable':
        if (label == '二课') return '缺少二课密码，请在手机验证后重试';
        if (label == '体测') return '缺少体测密码，请在手机验证后重试';
        return '教务登录状态已失效，请重新验证教务';
      case 'physical_credential_invalid':
        return '体测密码验证失败，请重新输入';
      case 'network_unavailable':
        return '网络连接失败，请重试';
      case 'provider_model_unavailable':
        return '当前回答模型暂不可用，管理员需要检查服务配置';
      case 'refresh_incomplete':
        return '$label更新不完整，可使用已有数据继续分析';
      case 'local_storage_failed':
        return '$label已获取，但本地加密保存失败';
      case 'device_refresh_not_fresh':
        return '$label刷新后仍未达到新鲜度要求';
      case 'agent_same_tool_budget_exhausted':
        return '课表查询重复步骤过多，请重新提问';
      case 'agent_duplicate_tool_call':
        return '检测到重复查询，请重新提问';
      case 'agent_planning_budget_exhausted':
        return '本次分析规划步骤达到上限，请重新提问';
    }
    return null;
  }

  static bool _isEduSessionCode(String code) {
    final normalized = code.trim().toLowerCase();
    return normalized == 'edu_authorization_revoked' ||
        normalized == 'edu_session_logged_out' ||
        normalized == 'edu_session_expired' ||
        normalized == 'edu_credential_unavailable';
  }

  static String _toolTitle(String toolName, String label) {
    if (toolName.contains('competition')) return '正在查找近期竞赛…';
    if (toolName.contains('canteen')) return '正在查看食堂评分…';
    return '正在读取$label数据…';
  }

  static String _datasetLabel(String dataset, String toolName) {
    if (toolName.contains('ensure_fresh_bundle')) return '学业';
    switch (dataset) {
      case 'grades':
        return '成绩';
      case 'credit_requirements':
      case 'credit_summary':
        return '学分要求';
      case 'academic_situation':
        return '学业情况';
      case 'academic':
        return '学业';
      case 'schedule':
        return '课表';
      case 'erke':
        return '二课';
      case 'physical':
        return '体测';
    }
    if (dataset.isNotEmpty) return '校园数据';
    if (toolName.contains('grade')) return '成绩';
    if (toolName.contains('schedule')) return '课表';
    if (toolName.contains('erke')) return '二课';
    if (toolName.contains('physical')) return '体测';
    if (toolName.contains('academic')) return '学业';
    return '校园数据';
  }
}
