class GradeReminderStatus {
  final bool supported;
  final bool enabled;
  final String state;
  final bool notificationGranted;
  final bool backgroundReady;
  final String? needAction;
  final String? year;
  final int? semester;
  final DateTime? lastCheckAt;
  final DateTime? lastSuccessAt;
  final int consecutiveFailures;

  const GradeReminderStatus({
    required this.supported,
    required this.enabled,
    required this.state,
    required this.notificationGranted,
    required this.backgroundReady,
    required this.needAction,
    required this.year,
    required this.semester,
    required this.lastCheckAt,
    required this.lastSuccessAt,
    required this.consecutiveFailures,
  });

  const GradeReminderStatus.unsupported()
      : supported = false,
        enabled = false,
        state = 'unsupported',
        notificationGranted = true,
        backgroundReady = true,
        needAction = null,
        year = null,
        semester = null,
        lastCheckAt = null,
        lastSuccessAt = null,
        consecutiveFailures = 0;

  factory GradeReminderStatus.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const GradeReminderStatus.unsupported();
    return GradeReminderStatus(
      supported: map['supported'] == true,
      enabled: map['enabled'] == true,
      state: map['state']?.toString() ?? 'off',
      notificationGranted: map['notificationGranted'] != false,
      backgroundReady: map['backgroundReady'] != false,
      needAction: _blankToNull(map['needAction']),
      year: _blankToNull(map['year']),
      semester: (map['semester'] as num?)?.toInt(),
      lastCheckAt: _dateFromMillis(map['lastCheckAt']),
      lastSuccessAt: _dateFromMillis(map['lastSuccessAt']),
      consecutiveFailures: (map['consecutiveFailures'] as num?)?.toInt() ?? 0,
    );
  }

  String get statusText {
    if (!supported) return '当前平台暂不支持';
    if (state == 'need_permission' || !notificationGranted) {
      return '通知权限未开启';
    }
    if (!enabled) return '未开启';
    switch (needAction) {
      case 'login':
        return '需要重新登录';
      case 'bind':
        return '需要重新绑定教务';
      case 'edu':
        return '教务服务暂不可用';
    }
    if (state == 'foreground_only') return '仅在打开 App 时检查';
    if (!backgroundReady) return '后台权限不足，可能延迟';
    if (state == 'checking') return '检查中';
    if (state == 'preparing') return '准备中';
    if (state == 'temporary_failed' || state == 'temp_failed') {
      return '教务服务暂不可用';
    }
    if (lastSuccessAt != null) {
      return '运行中 · 上次检查 ${_formatClock(lastSuccessAt!)}';
    }
    return '运行中';
  }

  static DateTime? _dateFromMillis(dynamic value) {
    final millis = (value as num?)?.toInt();
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static String? _blankToNull(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static String _formatClock(DateTime time) {
    final local = time.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
