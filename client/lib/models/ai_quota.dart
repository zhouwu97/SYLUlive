class AiQuota {
  final int limit;
  final int remaining;
  final int windowSeconds;
  final bool unlimited;
  final DateTime? resetAt;

  const AiQuota({
    required this.limit,
    required this.remaining,
    required this.windowSeconds,
    this.unlimited = false,
    this.resetAt,
  });

  factory AiQuota.fromJson(Map<String, dynamic> json) {
    return AiQuota(
      limit: _asInt(json['limit'], fallback: 3),
      remaining: _asInt(json['remaining'], fallback: 0),
      windowSeconds: _asInt(json['window_seconds'], fallback: 3600),
      unlimited: json['unlimited'] == true,
      resetAt: DateTime.tryParse(json['reset_at']?.toString() ?? '')?.toLocal(),
    );
  }

  AiQuota copyWith({int? remaining, DateTime? resetAt, bool? unlimited}) {
    return AiQuota(
      limit: limit,
      remaining: remaining ?? this.remaining,
      windowSeconds: windowSeconds,
      unlimited: unlimited ?? this.unlimited,
      resetAt: resetAt ?? this.resetAt,
    );
  }
}

int _asInt(dynamic value, {required int fallback}) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}
