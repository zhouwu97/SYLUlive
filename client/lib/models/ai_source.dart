enum AiSourceType { policy, schedule }

class AiSource {
  final AiSourceType type;
  final int chunkId;
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

  const AiSource({
    required this.type,
    this.chunkId = 0,
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
  });

  factory AiSource.fromJson(Map<String, dynamic> json) {
    return AiSource(
      type: json['type'] == 'schedule'
          ? AiSourceType.schedule
          : AiSourceType.policy,
      chunkId: int.tryParse(
              '${json['primary_chunk_id'] ?? json['chunk_id'] ?? ''}') ??
          0,
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
    );
  }

  String get typeLabel => type == AiSourceType.schedule ? '课表缓存' : '校园政策';

  String get reliabilityNote => type == AiSourceType.schedule
      ? '来自本机已同步课表缓存，并非实时教务数据。'
      : '请以来源文件当前有效版本为准。';

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
