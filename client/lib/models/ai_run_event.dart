import 'ai_quota.dart';
import 'ai_source.dart';
import 'ai_personal_data_evidence.dart';
import 'dart:convert';
import 'user_calendar.dart';

enum AiRunEventType {
  started,
  status,
  delta,
  checkpoint,
  sources,
  toolRequested,
  toolExecuting,
  deviceWaiting,
  deviceClaimed,
  consentRequired,
  eduFetching,
  toolCompleted,
  personalDataEvidence,
  completed,
  failed,
  cancelled,
  heartbeat,
  unknown,
}

class AiRunEvent {
  final String runId;
  final int seq;
  final AiRunEventType type;
  final String text;
  final String status;
  final List<AiSource> sources;
  final List<AiPersonalDataEvidence> personalDataEvidence;
  final List<String> datasets;
  final String consentScope;
  final String consentReason;
  final AiQuota? quota;
  final String errorCode;
  final bool retryable;
  final UserCalendarActionDraft? calendarActionDraft;

  const AiRunEvent({
    this.runId = '',
    this.seq = 0,
    required this.type,
    this.text = '',
    this.status = '',
    this.sources = const [],
    this.personalDataEvidence = const [],
    this.datasets = const [],
    this.consentScope = '',
    this.consentReason = '',
    this.quota,
    this.errorCode = '',
    this.retryable = false,
    this.calendarActionDraft,
  });

  factory AiRunEvent.fromJson(Map<String, dynamic> json, {String? eventName}) {
    final rawType = eventName ?? json['type']?.toString() ?? '';
    final payload = json['payload'] is Map
        ? Map<String, dynamic>.from(json['payload'] as Map)
        : <String, dynamic>{};
    final type = _eventType(rawType);
    final rawSources = payload['sources'];
    return AiRunEvent(
      runId: json['run_id']?.toString() ?? '',
      seq: _asInt(json['seq']),
      type: type,
      text: payload['text']?.toString() ?? '',
      status:
          payload['state']?.toString() ?? payload['status']?.toString() ?? '',
      sources: rawSources is List
          ? rawSources
              .whereType<Map>()
              .map((item) => AiSource.fromJson(Map<String, dynamic>.from(item)))
              .toList()
          : const [],
      personalDataEvidence: _evidence(payload['evidence']),
      datasets: _strings(payload['datasets']),
      consentScope: payload['scope']?.toString() ?? '',
      consentReason: payload['reason']?.toString() ?? '',
      errorCode: payload['code']?.toString() ?? '',
      retryable: payload['retryable'] == true,
      calendarActionDraft: payload['action_draft'] is Map
          ? UserCalendarActionDraft.fromJson(
              Map<String, dynamic>.from(payload['action_draft'] as Map),
            )
          : null,
      quota: payload['quota'] is Map
          ? AiQuota.fromJson(Map<String, dynamic>.from(payload['quota'] as Map))
          : null,
    );
  }

  static AiRunEvent parseSse(String data, {String? eventName}) {
    final decoded = jsonDecode(data);
    if (decoded is! Map) throw const FormatException('AI SSE 数据格式错误');
    return AiRunEvent.fromJson(Map<String, dynamic>.from(decoded),
        eventName: eventName);
  }
}

AiRunEventType _eventType(String type) {
  switch (type) {
    case 'run.created':
      return AiRunEventType.started;
    case 'run.state_changed':
    case 'retrieval.started':
    case 'retrieval.completed':
      return AiRunEventType.status;
    case 'answer.delta':
      return AiRunEventType.delta;
    case 'answer.checkpoint':
    case 'answer.completed':
      return AiRunEventType.checkpoint;
    case 'sources.ready':
      return AiRunEventType.sources;
    case 'tool.requested':
      return AiRunEventType.toolRequested;
    case 'tool.executing':
      return AiRunEventType.toolExecuting;
    case 'device.waiting':
      return AiRunEventType.deviceWaiting;
    case 'device.claimed':
      return AiRunEventType.deviceClaimed;
    case 'consent.required':
      return AiRunEventType.consentRequired;
    case 'edu.fetching':
      return AiRunEventType.eduFetching;
    case 'tool.completed':
      return AiRunEventType.toolCompleted;
    case 'personal_data.evidence':
      return AiRunEventType.personalDataEvidence;
    case 'run.completed':
      return AiRunEventType.completed;
    case 'run.failed':
      return AiRunEventType.failed;
    case 'run.cancelled':
      return AiRunEventType.cancelled;
    case 'heartbeat':
      return AiRunEventType.heartbeat;
    default:
      return AiRunEventType.unknown;
  }
}

int _asInt(dynamic value) =>
    value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;

List<AiPersonalDataEvidence> _evidence(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map(
        (item) => AiPersonalDataEvidence.fromJson(
          Map<String, dynamic>.from(item),
        ),
      )
      .where((item) => item.source.isNotEmpty)
      .toList(growable: false);
}

List<String> _strings(Object? value) {
  if (value is! List) return const [];
  return value
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}
