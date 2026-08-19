import 'ai_quota.dart';

class AiFeatures {
  final bool policyRag;
  final bool scheduleWindows;
  final bool hy3CompetitionCompare;
  final bool hy3AcademicAnalysis;
  final bool hy3WeekPlan;
  final bool academicAnalysis;

  const AiFeatures({
    required this.policyRag,
    required this.scheduleWindows,
    this.hy3CompetitionCompare = false,
    this.hy3AcademicAnalysis = false,
    this.hy3WeekPlan = false,
    this.academicAnalysis = false,
  });

  /// 统一模型的学业分析能力；旧字段仅为兼容历史服务端响应保留。
  bool get supportsAcademicAnalysis => academicAnalysis || hy3AcademicAnalysis;

  factory AiFeatures.fromJson(Map<String, dynamic> json) {
    return AiFeatures(
      policyRag: json['policy_rag'] == true,
      scheduleWindows: json['schedule_windows'] == true,
      hy3CompetitionCompare: json['hy3_competition_compare'] == true,
      hy3AcademicAnalysis: json['hy3_academic_analysis'] == true,
      hy3WeekPlan: json['hy3_week_plan'] == true,
      academicAnalysis: json['academic_analysis'] == true,
    );
  }
}

class AiCapabilities {
  static const int defaultMessageChars = 500;
  static const int maximumMessageChars = 500;

  final bool enabled;
  final bool accessAllowed;
  final bool internalTestOnly;
  final bool chatEnabled;
  final String phase;
  final AiFeatures features;
  final AiQuota quota;
  final int maxMessageChars;

  const AiCapabilities({
    required this.enabled,
    required this.accessAllowed,
    required this.internalTestOnly,
    required this.chatEnabled,
    required this.phase,
    required this.features,
    required this.quota,
    required this.maxMessageChars,
  });

  bool get isVisible => enabled && accessAllowed;

  factory AiCapabilities.fromJson(Map<String, dynamic> json) {
    final featureJson = json['features'];
    final quotaJson = json['quota'];
    final reportedMaxMessageChars = _positiveInt(
      json['max_message_chars'],
      fallback: defaultMessageChars,
    );
    return AiCapabilities(
      enabled: json['enabled'] == true,
      accessAllowed: json['access_allowed'] == true,
      internalTestOnly: json['internal_test_only'] == true,
      chatEnabled: json['chat_enabled'] == true,
      phase: json['phase']?.toString() ?? 'p0',
      features: AiFeatures.fromJson(
        featureJson is Map ? Map<String, dynamic>.from(featureJson) : const {},
      ),
      quota: AiQuota.fromJson(
        quotaJson is Map ? Map<String, dynamic>.from(quotaJson) : const {},
      ),
      maxMessageChars: reportedMaxMessageChars > maximumMessageChars
          ? maximumMessageChars
          : reportedMaxMessageChars,
    );
  }
}

int _positiveInt(dynamic value, {required int fallback}) {
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed > 0 ? parsed : fallback;
}
