import 'dart:convert';

class SecurityOverview {
  final String range;
  final int activeHighCount;
  final int actionableHighCount;
  final int actionablePendingCount;
  final int totalEvents;
  final int blockedRequests;
  final int affectedUsers;
  final int uniqueSources;
  final int emailAbuseCount;
  final int loginAbuseCount;
  final int criticalCount;
  final int mailSentCount;
  final int passwordResetSuccessCount;

  /// 后端是否返回了 actionable_* 口径。旧后端没有这两个字段，
  /// 此时回退到旧的 active_high_count，而不是把卡片显示成 0。
  final bool supportsActionableCounts;
  final Map<String, dynamic> protection;

  const SecurityOverview({
    required this.range,
    required this.activeHighCount,
    required this.actionableHighCount,
    required this.actionablePendingCount,
    required this.supportsActionableCounts,
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

  /// 首页「高危待处理」口径：待处置 + 未处理 + 高危/严重。
  ///
  /// 旧字段 activeHighCount 只按 status+severity 统计，会把已由封禁层处置掉的
  /// security_blocked_request 也算成待办，数字因此远大于列表里真正要处理的事。
  /// 新接口返回 actionable_high_count；旧后端未升级时回退到旧字段，避免显示 0。
  int get pendingHighCount =>
      actionableHighCount > 0 || totalEvents == 0
          ? actionableHighCount
          : activeHighCount;

  factory SecurityOverview.fromJson(Map<String, dynamic> json) {
    int number(String key) => (json[key] as num?)?.toInt() ?? 0;
    return SecurityOverview(
      range: json['range']?.toString() ?? '24h',
      activeHighCount: number('active_high_count'),
      actionableHighCount: number('actionable_high_count'),
      actionablePendingCount: number('actionable_pending_count'),
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
      supportsActionableCounts: json.containsKey('actionable_high_count'),
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

  /// 是否需要管理员处置。审计流水（正常验证码、正常改密、单次密码输错、
  /// 冷却拦截、已生效的来源封禁计数）为 false，默认列表不展示它们。
  final bool actionable;
  final Map<String, dynamic> metadata;
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
    required this.actionable,
    required this.metadata,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.resolvedAt,
    required this.resolutionNote,
  });

  /// 喷洒类事件涉及的账号/目标个数，来自服务端 metadata.distinct_targets。
  /// 缺失时返回 0，由展示层回退到尝试次数，不再显示成「目标：/api/login」。
  int get distinctTargets =>
      (metadata['distinct_targets'] as num?)?.toInt() ??
      (metadata['target_count'] as num?)?.toInt() ??
      0;

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
      actionable: json['actionable'] != false,
      metadata: _decodeMetadata(json['metadata_json']),
      firstSeenAt: date('first_seen_at'),
      lastSeenAt: date('last_seen_at'),
      resolvedAt: json['resolved_at'] == null
          ? null
          : DateTime.tryParse(json['resolved_at'].toString()),
      resolutionNote: json['resolution_note']?.toString() ?? '',
    );
  }

  /// metadata_json 是服务端白名单过滤后的 JSON 字符串；解析失败按「无元数据」处理，
  /// 不能让一条格式异常的历史记录把整个列表打挂。
  static Map<String, dynamic> _decodeMetadata(dynamic raw) {
    final text = raw?.toString() ?? '';
    if (text.isEmpty) return const {};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
    } on FormatException {
      return const {};
    }
  }
}
