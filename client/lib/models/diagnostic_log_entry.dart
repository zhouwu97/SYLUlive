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
  });

  factory DiagnosticLogEntry.fromMap(Map<Object?, Object?> map) {
    return DiagnosticLogEntry(
      id: map['id']?.toString() ?? '',
      timestamp: (map['timestamp'] as num?)?.toInt() ?? 0,
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
      firstSeenAt: (map['firstSeenAt'] as num?)?.toInt() ?? 0,
      lastSeenAt: (map['lastSeenAt'] as num?)?.toInt() ?? 0,
    );
  }

  bool get isError => level == 'error';
  bool get isWarning => level == 'warning';
  bool get isInfo => level == 'info';
}
