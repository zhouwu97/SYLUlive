class DiagnosticLogEntry {
  final String id;
  final int timestamp;
  final int elapsedRealtime;
  final String level;
  final String source;
  final String type;
  final String summary;
  final String detail;
  final String sessionId;
  final int pid;
  final String appVersion;
  final String manufacturer;
  final String model;
  final int sdkInt;
  final int repeatCount;
  final int firstSeenAt;
  final int lastSeenAt;
  final String eventCode;
  final String category;
  final String operation;
  final String result;
  final String traceId;
  final int? durationMs;
  final int? httpStatus;
  final int retryCount;
  final String route;
  final int? taskId;
  final bool? isForeground;
  final Map<String, Object?> metadata;

  DiagnosticLogEntry({
    required this.id,
    required this.timestamp,
    required this.elapsedRealtime,
    required this.level,
    required this.source,
    required this.type,
    required this.summary,
    required this.detail,
    required this.sessionId,
    required this.pid,
    required this.appVersion,
    required this.manufacturer,
    required this.model,
    required this.sdkInt,
    required this.repeatCount,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.eventCode = '',
    this.category = 'app',
    this.operation = '',
    this.result = '',
    this.traceId = '',
    this.durationMs,
    this.httpStatus,
    this.retryCount = 0,
    this.route = '',
    this.taskId,
    this.isForeground,
    this.metadata = const <String, Object?>{},
  });

  factory DiagnosticLogEntry.fromMap(Map<Object?, Object?> map) {
    final timestamp = (map['timestamp'] as num?)?.toInt() ?? 0;
    return DiagnosticLogEntry(
      id: map['id']?.toString() ?? '',
      timestamp: timestamp,
      elapsedRealtime: (map['elapsedRealtime'] as num?)?.toInt() ?? 0,
      level: map['level']?.toString() ?? 'info',
      source: map['source']?.toString() ?? '未知',
      type: map['type']?.toString() ?? '未知',
      summary: map['summary']?.toString() ?? '',
      detail: map['detail']?.toString() ?? '',
      sessionId: map['sessionId']?.toString() ?? '',
      pid: (map['pid'] as num?)?.toInt() ?? 0,
      appVersion: map['appVersion']?.toString() ?? '',
      manufacturer: map['manufacturer']?.toString() ?? '',
      model: map['model']?.toString() ?? '',
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
      repeatCount: (map['repeatCount'] as num?)?.toInt() ?? 1,
      firstSeenAt: (map['firstSeenAt'] as num?)?.toInt() ?? timestamp,
      lastSeenAt: (map['lastSeenAt'] as num?)?.toInt() ?? timestamp,
      eventCode: map['eventCode']?.toString() ?? '',
      category: map['category']?.toString() ?? 'app',
      operation: map['operation']?.toString() ?? '',
      result: map['result']?.toString() ?? '',
      traceId: map['traceId']?.toString() ?? '',
      durationMs: (map['durationMs'] as num?)?.toInt(),
      httpStatus: (map['httpStatus'] as num?)?.toInt(),
      retryCount: (map['retryCount'] as num?)?.toInt() ?? 0,
      route: map['route']?.toString() ?? '',
      taskId: (map['taskId'] as num?)?.toInt(),
      isForeground: map['isForeground'] as bool?,
      metadata: _stringKeyedMap(map['metadata']),
    );
  }

  bool get isError => level == 'error';
  bool get isWarning => level == 'warning';
  bool get isInfo => level == 'info';
}

Map<String, Object?> _stringKeyedMap(Object? value) {
  if (value is! Map) return const <String, Object?>{};
  return Map<String, Object?>.unmodifiable(
    value.map((key, item) => MapEntry(key.toString(), item)),
  );
}
