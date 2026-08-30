import 'ai_run_event.dart';

enum AiAgentActivityStatus { pending, running, success, failed }

/// Agent 过程的用户可见语义；不把 MCP、DeviceJob 或内部 scope 直接交给 UI。
class AiAgentActivity {
  const AiAgentActivity({
    required this.id,
    required this.runId,
    required this.code,
    required this.dataset,
    required this.status,
    required this.title,
    required this.detail,
    required this.timestamp,
    this.toolName = '',
    this.callId = '',
    this.jobId = '',
    this.freshnessBefore = '',
    this.freshnessAfter = '',
    this.errorCode = '',
    this.success = false,
  });

  final String id;
  final String runId;
  final String code;
  final String dataset;
  final AiAgentActivityStatus status;
  final String title;
  final String detail;
  final DateTime timestamp;
  final String toolName;
  final String callId;
  final String jobId;
  final String freshnessBefore;
  final String freshnessAfter;
  final String errorCode;
  final bool success;

  bool get isRunning => status == AiAgentActivityStatus.running;

  factory AiAgentActivity.fromEvent(AiRunEvent event) {
    return AiAgentActivity(
      id: '${event.runId}:${event.seq}:${event.activityCode}:${event.jobId}',
      runId: event.runId,
      code: event.activityCode,
      dataset: event.dataset,
      status: AiAgentActivityStatus.pending,
      title: event.text,
      detail: '',
      timestamp: event.timestamp ?? DateTime.fromMillisecondsSinceEpoch(0),
      toolName: event.toolName,
      callId: event.callId,
      jobId: event.jobId,
      freshnessBefore: event.freshnessBefore,
      freshnessAfter: event.freshnessAfter,
      errorCode: event.errorCode,
      success: event.success,
    );
  }
}
