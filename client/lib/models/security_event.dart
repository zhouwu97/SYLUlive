class SecurityOverview {
  final String range;
  final int activeHighCount;
  final int totalEvents;
  final int blockedRequests;
  final int affectedUsers;
  final int uniqueSources;
  final int emailAbuseCount;
  final int loginAbuseCount;
  final int criticalCount;
  final int mailSentCount;
  final int passwordResetSuccessCount;
  final Map<String, dynamic> protection;

  const SecurityOverview({
    required this.range,
    required this.activeHighCount,
    required this.totalEvents,
    required this.blockedRequests,
    required this.affectedUsers,
    required this.uniqueSources,
    required this.emailAbuseCount,
    required this.loginAbuseCount,
    required this.criticalCount,
    required this.mailSentCount,
    required this.passwordResetSuccessCount,
    required this.protection,
  });

  factory SecurityOverview.fromJson(Map<String, dynamic> json) {
    int number(String key) => (json[key] as num?)?.toInt() ?? 0;
    return SecurityOverview(
      range: json['range']?.toString() ?? '24h',
      activeHighCount: number('active_high_count'),
      totalEvents: number('total_events'),
      blockedRequests: number('blocked_requests'),
      affectedUsers: number('affected_targets') != 0
          ? number('affected_targets')
          : number('affected_users'),
      uniqueSources: number('unique_sources'),
      emailAbuseCount: number('email_abuse_count'),
      loginAbuseCount: number('login_abuse_count'),
      criticalCount: number('critical_count'),
      mailSentCount: number('mail_sent_count'),
      passwordResetSuccessCount: number('password_reset_success_count'),
      protection: json['protection'] is Map
          ? Map<String, dynamic>.from(json['protection'] as Map)
          : const {},
    );
  }
}

class SecurityEvent {
  final int id;
  final String eventType;
  final String severity;
  final String status;
  final String route;
  final String method;
  final String sourceFingerprint;
  final String sourceKey;
  final bool installationSeen;
  final int? actorUserId;
  final String targetType;
  final String targetMasked;
  final String requestIdSample;
  final int attemptCount;
  final int blockedCount;
  final int mailSentCount;
  final int passwordResetSuccessCount;
  final bool sourceAttributionValid;
  final String action;
  final String metadataJson;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final DateTime? resolvedAt;
  final String resolutionNote;

  const SecurityEvent({
    required this.id,
    required this.eventType,
    required this.severity,
    required this.status,
    required this.route,
    required this.method,
    required this.sourceFingerprint,
    required this.sourceKey,
    required this.installationSeen,
    required this.actorUserId,
    required this.targetType,
    required this.targetMasked,
    required this.requestIdSample,
    required this.attemptCount,
    required this.blockedCount,
    required this.mailSentCount,
    required this.passwordResetSuccessCount,
    required this.sourceAttributionValid,
    required this.action,
    required this.metadataJson,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.resolvedAt,
    required this.resolutionNote,
  });

  factory SecurityEvent.fromJson(Map<String, dynamic> json) {
    DateTime date(String key) =>
        DateTime.tryParse(json[key]?.toString() ?? '') ?? DateTime.now();
    return SecurityEvent(
      id: (json['id'] as num?)?.toInt() ?? 0,
      eventType: json['event_type']?.toString() ?? '',
      severity: json['severity']?.toString() ?? 'medium',
      status: json['status']?.toString() ?? 'active',
      route: json['route']?.toString() ?? '',
      method: json['method']?.toString() ?? '',
      sourceFingerprint: json['source_fingerprint']?.toString() ?? '',
      sourceKey: json['source_key']?.toString() ?? '',
      installationSeen: json['installation_seen'] == true,
      actorUserId: (json['actor_user_id'] as num?)?.toInt(),
      targetType: json['target_type']?.toString() ?? '',
      targetMasked: json['target_masked']?.toString() ?? '',
      requestIdSample: json['request_id_sample']?.toString() ?? '',
      attemptCount: (json['attempt_count'] as num?)?.toInt() ?? 0,
      blockedCount: (json['blocked_count'] as num?)?.toInt() ?? 0,
      mailSentCount: (json['mail_sent_count'] as num?)?.toInt() ?? 0,
      passwordResetSuccessCount:
          (json['password_reset_success_count'] as num?)?.toInt() ?? 0,
      sourceAttributionValid: json['source_attribution_valid'] != false,
      action: json['action']?.toString() ?? '',
      metadataJson: json['metadata_json']?.toString() ?? '',
      firstSeenAt: date('first_seen_at'),
      lastSeenAt: date('last_seen_at'),
      resolvedAt: json['resolved_at'] == null
          ? null
          : DateTime.tryParse(json['resolved_at'].toString()),
      resolutionNote: json['resolution_note']?.toString() ?? '',
    );
  }
}
