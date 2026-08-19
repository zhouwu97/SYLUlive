enum AiSourceType { policy, schedule, competitionCatalog, competitionEvidence }

class AiSource {
  final AiSourceType type;
  final int chunkId;

  /// 一张来源卡可能由多个检索 chunk 组成；旧接口只有 primary_chunk_id，
  /// 因此始终把 [chunkId] 作为兼容主键保留。
  final List<int> chunkIds;
  final int documentId;
  final String title;
  final String publisher;
  final String status;
  final String confidence;
  final String? url;
  final List<int> citationNumbers;
  final List<String> locators;
  final DateTime? effectiveFrom;
  final DateTime? effectiveTo;
  final DateTime? publishedAt;
  final String competitionId;
  final String datasetVersion;
  final String schoolRecognition;
  final String competitionRating;
  final String evidenceSubgrade;
  final String aiMode;
  final DateTime? lastUpdated;

  const AiSource({
    required this.type,
    this.chunkId = 0,
    this.chunkIds = const [],
    this.documentId = 0,
    required this.title,
    this.publisher = '',
    this.status = '',
    this.confidence = '',
    this.url,
    this.citationNumbers = const [],
    this.locators = const [],
    this.effectiveFrom,
    this.effectiveTo,
    this.publishedAt,
    this.competitionId = '',
    this.datasetVersion = '',
    this.schoolRecognition = '',
    this.competitionRating = '',
    this.evidenceSubgrade = '',
    this.aiMode = '',
    this.lastUpdated,
  });

  factory AiSource.fromJson(Map<String, dynamic> json) {
    final primaryChunkId =
        int.tryParse('${json['primary_chunk_id'] ?? json['chunk_id'] ?? ''}') ??
            0;
    final chunkIds = _intList(json['chunk_ids']);
    final normalizedChunkIds = <int>{
      if (primaryChunkId > 0) primaryChunkId,
      ...chunkIds,
    }.toList(growable: false);
    return AiSource(
      type: _sourceType(json['type']),
      chunkId: primaryChunkId,
      chunkIds: normalizedChunkIds,
      documentId: int.tryParse('${json['document_id'] ?? ''}') ?? 0,
      title: json['title']?.toString() ?? '',
      publisher:
          json['publisher']?.toString() ?? json['department']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      confidence: json['confidence']?.toString() ?? '',
      url: json['url']?.toString(),
      citationNumbers: _intList(json['citation_numbers']),
      locators: _stringList(json['locators']),
      effectiveFrom: _policyDate(json['effective_from']),
      effectiveTo: _policyDate(json['effective_to']),
      publishedAt: _dateTime(json['published_at']),
      competitionId: json['competition_id']?.toString() ?? '',
      datasetVersion: json['dataset_version']?.toString() ?? '',
      schoolRecognition: json['school_recognition']?.toString() ??
          json['school_recognition_grade']?.toString() ??
          '',
      competitionRating: json['competition_rating']?.toString() ?? '',
      evidenceSubgrade: json['evidence_subgrade']?.toString() ?? '',
      aiMode: json['ai_mode']?.toString() ?? '',
      lastUpdated: _dateTime(json['last_updated'] ?? json['updated_at']),
    );
  }

  String get typeLabel {
    switch (type) {
      case AiSourceType.schedule:
        return '课表缓存';
      case AiSourceType.competitionCatalog:
        return '竞赛目录';
      case AiSourceType.competitionEvidence:
        return '竞赛证据';
      case AiSourceType.policy:
        return '校园政策';
    }
  }

  String get reliabilityNote {
    switch (type) {
      case AiSourceType.schedule:
        return '来自本机已同步课表缓存，并非实时教务数据。';
      case AiSourceType.competitionCatalog:
      case AiSourceType.competitionEvidence:
        return '仅展示公开目录事实；候选解释不代表获奖概率。';
      case AiSourceType.policy:
        return '请以来源文件当前有效版本为准。';
    }
  }

  String get citationLabel =>
      citationNumbers.map((number) => '[$number]').join();

  String get departmentLabel =>
      publisher.trim().isEmpty ? '未标注' : publisher.trim();

  String get statusLabel {
    switch (status.trim().toLowerCase()) {
      case 'published':
        return '已发布';
      case 'revoked':
        return '已撤销';
      case 'superseded':
        return '已被替代';
      case 'draft':
        return '草稿';
      default:
        return status.trim().isEmpty ? '未标注' : status.trim();
    }
  }

  String get effectiveLabel {
    final from = effectiveFrom == null ? '' : _formatDate(effectiveFrom!);
    final to = effectiveTo == null ? '' : _formatDate(effectiveTo!);
    if (from.isNotEmpty && to.isNotEmpty) return '$from 至 $to';
    if (from.isNotEmpty) return '$from 起';
    if (to.isNotEmpty) return '截至 $to';
    return '未标注';
  }

  String get locatorLabel => locators.isEmpty ? '未标注' : locators.join(' · ');

  String get stableKey =>
      '${type.name}:$documentId:${chunkIds.isEmpty ? chunkId : chunkIds.join(',')}:$title';

  AiSource copyWith({
    List<int>? citationNumbers,
    List<int>? chunkIds,
  }) {
    return AiSource(
      type: type,
      chunkId: chunkId,
      chunkIds: chunkIds ?? this.chunkIds,
      documentId: documentId,
      title: title,
      publisher: publisher,
      status: status,
      confidence: confidence,
      url: url,
      citationNumbers: citationNumbers ?? this.citationNumbers,
      locators: locators,
      effectiveFrom: effectiveFrom,
      effectiveTo: effectiveTo,
      publishedAt: publishedAt,
      competitionId: competitionId,
      datasetVersion: datasetVersion,
      schoolRecognition: schoolRecognition,
      competitionRating: competitionRating,
      evidenceSubgrade: evidenceSubgrade,
      aiMode: aiMode,
      lastUpdated: lastUpdated,
    );
  }
}

AiSourceType _sourceType(dynamic value) {
  switch (value?.toString()) {
    case 'schedule':
      return AiSourceType.schedule;
    case 'competition_catalog':
      return AiSourceType.competitionCatalog;
    case 'competition_evidence':
      return AiSourceType.competitionEvidence;
    default:
      return AiSourceType.policy;
  }
}

class AiSourceContent {
  final int chunkId;
  final int documentId;
  final String title;
  final String content;
  final String sectionTitle;
  final String locator;

  const AiSourceContent({
    required this.chunkId,
    required this.documentId,
    required this.title,
    required this.content,
    this.sectionTitle = '',
    this.locator = '',
  });

  factory AiSourceContent.fromJson(Map<String, dynamic> json) {
    return AiSourceContent(
      chunkId: int.tryParse('${json['chunk_id'] ?? ''}') ?? 0,
      documentId: int.tryParse('${json['document_id'] ?? ''}') ?? 0,
      title: json['title']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      sectionTitle: json['section_title']?.toString() ?? '',
      locator: json['locator']?.toString() ?? '',
    );
  }
}

List<int> _intList(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((item) => int.tryParse(item.toString()) ?? 0)
      .where((item) => item > 0)
      .toList(growable: false);
}

List<String> _stringList(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((item) => item.toString().trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

DateTime? _dateTime(dynamic value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

// 政策生效区间是日期语义，不能因终端时区换算而偏移一天。
DateTime? _policyDate(dynamic value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) return null;
  final matched = RegExp(r'^\d{4}-\d{2}-\d{2}').firstMatch(raw)?.group(0);
  return DateTime.tryParse(matched ?? raw);
}

String _formatDate(DateTime value) {
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
