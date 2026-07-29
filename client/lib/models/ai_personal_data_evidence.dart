class AiPersonalDataEvidence {
  const AiPersonalDataEvidence({
    required this.source,
    this.dataset = '',
    this.title = '',
    this.fetchedAt,
    this.expiresAt,
    this.isStale = false,
  });

  final String source;
  final String dataset;
  final String title;
  final DateTime? fetchedAt;
  final DateTime? expiresAt;
  final bool isStale;

  factory AiPersonalDataEvidence.fromJson(Map<String, dynamic> json) {
    return AiPersonalDataEvidence(
      source: json['source']?.toString() ?? '',
      dataset: json['dataset']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      fetchedAt: _parseTime(json['fetched_at']),
      expiresAt: _parseTime(json['expires_at']),
      isStale: json['is_stale'] == true,
    );
  }

  String get sourceLabel => switch (source) {
        'server_snapshot' => '服务端教务快照',
        'device_encrypted_cache' => '手机本地加密缓存',
        'remote_edu_fetch' => '实时教务拉取',
        'user_uploaded_snapshot' => '用户上传快照',
        _ => '个人数据来源',
      };

  String get datasetLabel => switch (dataset) {
        'grades' => '成绩',
        'schedule' => '课表',
        'academic_situation' => '学业情况',
        'credit_requirements' => '学分要求',
        'credit_summary' => '学分摘要',
        'erke' => '二课',
        _ => title,
      };

  String get stableKey =>
      '$source|$dataset|$title|${fetchedAt?.toUtc().toIso8601String() ?? ''}';

  static DateTime? _parseTime(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value)?.toLocal();
  }
}
